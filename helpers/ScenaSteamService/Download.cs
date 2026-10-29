using System.Collections.Concurrent;
using System.Security.Cryptography;
using SteamKit2;
using SteamKit2.CDN;
using SteamKit2.Internal;

// Workshop downloads straight from Steam's content CDN (no steamcmd).
// Each item: published file details -> manifest -> chunks (decrypted, decompressed and
// Adler-checked by SteamKit) written into <staging>/<id>, then moved to <content>/<id>.
// Staging survives pause/cancel so a later run only fetches chunks that are still missing.
internal static partial class Program
{
    private const uint WallpaperEngineAppId = 431960;

    private sealed record ChunkJob(SafeFileHandleRef File, DepotManifest.ChunkData Chunk);

    /// Shared per-file handle; RandomAccess writes at explicit offsets are safe from several tasks.
    private sealed class SafeFileHandleRef(Microsoft.Win32.SafeHandles.SafeFileHandle handle) : IDisposable
    {
        public Microsoft.Win32.SafeHandles.SafeFileHandle Handle { get; } = handle;
        public void Dispose() => Handle.Dispose();
    }

    private static async Task Download(Request request, CancellationToken cancellation)
    {
        ValidateStoredCredential(request);
        var ids = request.Ids ?? throw new ServiceFailure("protocol");
        if (ids.Length is 0 or > 50 || ids.Any(id => id.Length is 0 or > 20 || !id.All(char.IsAsciiDigit)))
            throw new ServiceFailure("protocol");
        var contentRoot = ValidatedDirectory(request.ContentRoot);
        var stagingRoot = ValidatedDirectory(request.StagingRoot);
        var concurrency = Math.Clamp(request.Concurrency, 1, 16);

        await using var session = new Session(cancellation);
        Emit(new { v = 1, id = request.Id, type = "connecting" });
        await session.ConnectAsync(cancellation);
        Emit(new { v = 1, id = request.Id, type = "authorizing" });
        await session.LogOnAsync(request.AccountName!, request.RefreshToken!, request.LoginId, cancellation);

        var client = session.Client;
        var published = client.GetHandler<SteamUnifiedMessages>()?.CreateService<PublishedFile>() ?? throw new ServiceFailure("protocol");
        var detailsRequest = new CPublishedFile_GetDetails_Request();
        detailsRequest.publishedfileids.AddRange(ids.Select(ulong.Parse));
        var details = await published.GetDetails(detailsRequest).ToTask().WaitAsync(cancellation);
        if (details.Result != EResult.OK) throw new ServiceFailure("connection");
        var byId = details.Body.publishedfiledetails.ToDictionary(item => item.publishedfileid.ToString());

        using var cdn = new Client(client);
        var context = new Lazy<Task<(byte[] Key, List<Server> Servers)>>(() => PrepareDepot(client, cancellation));
        foreach (var itemId in ids)
        {
            cancellation.ThrowIfCancellationRequested();
            try
            {
                if (!byId.TryGetValue(itemId, out var item) || (EResult)item.result != EResult.OK
                    || item.consumer_appid != WallpaperEngineAppId || item.banned)
                    throw new ServiceFailure("unavailable");
                var staging = Path.Combine(stagingRoot, itemId);
                Directory.CreateDirectory(staging);
                if (item.hcontent_file != 0)
                {
                    var (key, servers) = await context.Value;
                    await DownloadManifestItem(request.Id, itemId, item.hcontent_file, client, cdn, key, servers,
                        staging, Path.Combine(contentRoot, itemId), concurrency, cancellation);
                }
                else if (Uri.TryCreate(item.file_url, UriKind.Absolute, out var url) && url.Scheme == Uri.UriSchemeHttps)
                {
                    await DownloadLegacyFile(request.Id, itemId, url, item.filename, item.file_size, staging, cancellation);
                }
                else throw new ServiceFailure("unavailable");
                var folder = Install(staging, Path.Combine(contentRoot, itemId));
                Emit(new { v = 1, id = request.Id, type = "itemDone", itemId, folder,
                    manifestId = item.hcontent_file.ToString(), updatedAt = item.time_updated });
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
            catch (ServiceFailure failure) when (failure.Code is "unavailable" or "notOwned" or "storage")
            {
                // Item-level problems; continue with the rest of the batch.
                Emit(new { v = 1, id = request.Id, type = "itemError", itemId, code = failure.Code });
                if (failure.Code == "notOwned") throw;
            }
            catch (IOException)
            {
                Emit(new { v = 1, id = request.Id, type = "itemError", itemId, code = "storage" });
            }
            catch (UnauthorizedAccessException)
            {
                Emit(new { v = 1, id = request.Id, type = "itemError", itemId, code = "storage" });
            }
            catch (Exception) when (!cancellation.IsCancellationRequested)
            {
                Emit(new { v = 1, id = request.Id, type = "itemError", itemId, code = "connection" });
            }
        }
        Emit(new { v = 1, id = request.Id, type = "done" });
    }

    private static string ValidatedDirectory(string? path)
    {
        if (string.IsNullOrEmpty(path) || !Path.IsPathFullyQualified(path)) throw new ServiceFailure("protocol");
        var full = Path.GetFullPath(path);
        Directory.CreateDirectory(full);
        return full;
    }

    /// Depot key (requires owning Wallpaper Engine) and CDN servers that may serve this app.
    private static async Task<(byte[] Key, List<Server> Servers)> PrepareDepot(SteamClient client, CancellationToken cancellation)
    {
        var apps = client.GetHandler<SteamApps>() ?? throw new ServiceFailure("protocol");
        var content = client.GetHandler<SteamContent>() ?? throw new ServiceFailure("protocol");
        var depotKey = await apps.GetDepotDecryptionKey(WallpaperEngineAppId, WallpaperEngineAppId).ToTask().WaitAsync(cancellation);
        if (depotKey.Result == EResult.AccessDenied || depotKey.Result == EResult.Blocked) throw new ServiceFailure("notOwned");
        if (depotKey.Result != EResult.OK) throw new ServiceFailure("connection");
        var servers = (await content.GetServersForSteamPipe().WaitAsync(cancellation))
            .Where(server => server.Type is "SteamCache" or "CDN"
                && (server.AllowedAppIds.Length == 0 || server.AllowedAppIds.Contains(WallpaperEngineAppId)))
            .OrderBy(server => server.WeightedLoad).ToList();
        if (servers.Count == 0) throw new ServiceFailure("connection");
        return (depotKey.DepotKey, servers);
    }

    private static async Task DownloadManifestItem(string requestId, string itemId, ulong manifestId, SteamClient client,
        Client cdn, byte[] depotKey, List<Server> servers, string staging, string installed, int concurrency,
        CancellationToken cancellation)
    {
        var content = client.GetHandler<SteamContent>() ?? throw new ServiceFailure("protocol");
        var requestCode = await content.GetManifestRequestCode(WallpaperEngineAppId, WallpaperEngineAppId, manifestId, "public")
            .WaitAsync(cancellation);
        var manifest = await WithServers(servers, 0, server =>
            cdn.DownloadManifestAsync(WallpaperEngineAppId, manifestId, requestCode, server, depotKey), cancellation);
        var files = (manifest.Files ?? []).Where(file => !file.Flags.HasFlag(EDepotFileFlag.Directory)).ToList();
        var total = files.Sum(file => (long)file.TotalSize);
        long received = 0;

        // Keep staging limited to the manifest so the installed folder matches it exactly.
        var expected = new HashSet<string>(files.Select(file => SafeChild(staging, file.FileName)), StringComparer.OrdinalIgnoreCase);
        foreach (var stale in Directory.EnumerateFiles(staging, "*", SearchOption.AllDirectories))
            if (!expected.Contains(Path.GetFullPath(stale))) File.Delete(stale);
        foreach (var directory in (manifest.Files ?? []).Where(file => file.Flags.HasFlag(EDepotFileFlag.Directory)))
            Directory.CreateDirectory(SafeChild(staging, directory.FileName));

        var handles = new List<SafeFileHandleRef>();
        var jobs = new List<ChunkJob>();
        try
        {
            foreach (var file in files)
            {
                cancellation.ThrowIfCancellationRequested();
                var target = SafeChild(staging, file.FileName);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                // Unchanged files from the installed copy (re-download / update) are reused, not fetched.
                var current = SafeChild(installed, file.FileName);
                if (!File.Exists(target) && File.Exists(current) && new FileInfo(current).Length == (long)file.TotalSize
                    && await HashMatches(current, file.FileHash, cancellation))
                {
                    File.Copy(current, target, overwrite: true);
                    received += (long)file.TotalSize;
                    continue;
                }
                var handle = new SafeFileHandleRef(File.OpenHandle(target, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None));
                handles.Add(handle);
                var resumable = RandomAccess.GetLength(handle.Handle) == (long)file.TotalSize;
                if (!resumable) RandomAccess.SetLength(handle.Handle, (long)file.TotalSize);
                foreach (var chunk in file.Chunks)
                {
                    // A chunk already in staging (from a paused run) passes the same checksum SteamKit uses.
                    if (resumable && ChunkPresent(handle, chunk)) received += chunk.UncompressedLength;
                    else jobs.Add(new ChunkJob(handle, chunk));
                }
            }

            using var progressStop = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            var reporter = Task.Run(async () =>
            {
                while (!progressStop.IsCancellationRequested)
                {
                    Emit(new { v = 1, id = requestId, type = "progress", itemId, receivedBytes = Interlocked.Read(ref received), totalBytes = total });
                    try { await Task.Delay(250, progressStop.Token); } catch (OperationCanceledException) { return; }
                }
            }, CancellationToken.None);

            var index = 0;
            try
            {
                await Parallel.ForEachAsync(jobs, new ParallelOptions { MaxDegreeOfParallelism = concurrency, CancellationToken = cancellation },
                    async (job, token) =>
                    {
                        var buffer = new byte[job.Chunk.UncompressedLength];
                        var start = Interlocked.Increment(ref index);
                        var written = await WithServers(servers, start, server =>
                            cdn.DownloadDepotChunkAsync(WallpaperEngineAppId, job.Chunk, server, buffer, depotKey), token);
                        await RandomAccess.WriteAsync(job.File.Handle, buffer.AsMemory(0, written), (long)job.Chunk.Offset, token);
                        Interlocked.Add(ref received, written);
                    });
            }
            finally
            {
                await progressStop.CancelAsync();
                await reporter;
            }
            Emit(new { v = 1, id = requestId, type = "progress", itemId, receivedBytes = total, totalBytes = total });
        }
        finally
        {
            handles.ForEach(handle => handle.Dispose());
        }
    }

    /// Tries servers round-robin from <paramref name="start"/>, with a short backoff between full rounds.
    private static async Task<T> WithServers<T>(List<Server> servers, int start, Func<Server, Task<T>> operation, CancellationToken cancellation)
    {
        Exception? last = null;
        for (var attempt = 0; attempt < Math.Max(4, servers.Count); attempt++)
        {
            cancellation.ThrowIfCancellationRequested();
            try { return await operation(servers[(start + attempt) % servers.Count]).WaitAsync(cancellation); }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
            catch (Exception error)
            {
                last = error;
                if ((attempt + 1) % servers.Count == 0) await Task.Delay(TimeSpan.FromSeconds(1 + attempt), cancellation);
            }
        }
        throw last ?? new ServiceFailure("connection");
    }

    private static bool ChunkPresent(SafeFileHandleRef file, DepotManifest.ChunkData chunk)
    {
        var buffer = new byte[chunk.UncompressedLength];
        var read = RandomAccess.Read(file.Handle, buffer, (long)chunk.Offset);
        return read == buffer.Length && DepotChunk.AdlerHash(buffer) == chunk.Checksum;
    }

    private static async Task<bool> HashMatches(string path, byte[] expected, CancellationToken cancellation)
    {
        await using var stream = File.OpenRead(path);
        return (await SHA1.HashDataAsync(stream, cancellation)).AsSpan().SequenceEqual(expected);
    }

    /// Manifest names are untrusted: reject anything that would land outside the item folder.
    private static string SafeChild(string root, string relative)
    {
        var full = Path.GetFullPath(Path.Combine(root, relative));
        if (!full.StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new ServiceFailure("unavailable");
        return full;
    }

    private static async Task DownloadLegacyFile(string requestId, string itemId, Uri url, string? filename, ulong size,
        string staging, CancellationToken cancellation)
    {
        var name = Path.GetFileName(filename ?? "");
        if (string.IsNullOrEmpty(name)) throw new ServiceFailure("unavailable");
        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellation);
        if (!response.IsSuccessStatusCode) throw new ServiceFailure("connection");
        var total = response.Content.Headers.ContentLength ?? (long)size;
        await using var input = await response.Content.ReadAsStreamAsync(cancellation);
        await using var output = File.Create(SafeChild(staging, name));
        var buffer = new byte[1 << 16];
        long received = 0;
        var lastReport = DateTime.MinValue;
        int read;
        while ((read = await input.ReadAsync(buffer, cancellation)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, read), cancellation);
            received += read;
            if (DateTime.UtcNow - lastReport > TimeSpan.FromMilliseconds(250))
            {
                lastReport = DateTime.UtcNow;
                Emit(new { v = 1, id = requestId, type = "progress", itemId, receivedBytes = received, totalBytes = total });
            }
        }
    }

    /// Swap the finished staging folder in; the previous copy is removed only after the move succeeds.
    private static string Install(string staging, string installed)
    {
        string? previous = null;
        if (Directory.Exists(installed))
        {
            previous = installed + ".replaced-" + Guid.NewGuid().ToString("N");
            Directory.Move(installed, previous);
        }
        try { Directory.Move(staging, installed); }
        catch
        {
            if (previous != null) Directory.Move(previous, installed);
            throw new ServiceFailure("storage");
        }
        if (previous != null) { try { Directory.Delete(previous, recursive: true); } catch (IOException) { } }
        return installed;
    }
}
