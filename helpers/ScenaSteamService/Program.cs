using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SteamKit2;
using SteamKit2.Authentication;

// One operation per process. stdin/stdout are private pipes owned by Scena;
// no HTTP listener, passwords, credential files, or token-bearing log messages.
internal static partial class Program
{
    private static readonly object OutputLock = new();
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private sealed record Request(int V, string Id, string Method, uint LoginId = 0,
        string? AccountName = null, string? RefreshToken = null,
        string[]? Ids = null, string? ContentRoot = null, string? StagingRoot = null, int Concurrency = 8);
    private sealed class ServiceFailure(string code) : Exception { public string Code { get; } = code; }

    private static void Emit(object message)
    {
        lock (OutputLock) { Console.Out.WriteLine(JsonSerializer.Serialize(message, Json)); Console.Out.Flush(); }
    }

    public static async Task<int> Main()
    {
        Console.InputEncoding = Encoding.UTF8;
        Console.OutputEncoding = new UTF8Encoding(false);
        Emit(new { v = 1, type = "ready" });
        Request? request = null;
        try
        {
            using var startup = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var line = await Console.In.ReadLineAsync(startup.Token);
            if (line is null || line.Length > 65536) throw new ServiceFailure("protocol");
            request = JsonSerializer.Deserialize<Request>(line, new JsonSerializerOptions(Json) { PropertyNameCaseInsensitive = true });
            if (request is null || request.V != 1 || !Guid.TryParse(request.Id, out _)) throw new ServiceFailure("protocol");
            if (request.Method == "ping")
            {
                Emit(new { v = 1, id = request.Id, type = "pong" });
                return 0;
            }
            if (request.Method is not ("qr" or "restore" or "download")) throw new ServiceFailure("protocol");
            if (request.LoginId == 0) throw new ServiceFailure("protocol");
            // Downloads end on completion, cancellation, or parent EOF; large items can take hours.
            var limit = request.Method switch { "qr" => TimeSpan.FromSeconds(240), "restore" => TimeSpan.FromSeconds(50), _ => TimeSpan.FromHours(12) };
            using var lifetime = new CancellationTokenSource(limit);
            // EOF means the parent went away; cancel rather than leaving a login alive.
            // Console.In can synchronously block even in ReadLineAsync; keep the
            // parent monitor off the authentication continuation.
            _ = Task.Run(() => WatchParent(lifetime));
            if (request.Method == "download") await Download(request, lifetime.Token);
            else await Authenticate(request, lifetime.Token);
            return 0;
        }
        catch (OperationCanceledException)
        {
            Emit(new { v = 1, id = request?.Id, type = "error", code = "timeout" });
        }
        catch (ServiceFailure failure)
        {
            Emit(new { v = 1, id = request?.Id, type = "error", code = failure.Code });
        }
        catch (AuthenticationException failure)
        {
            Emit(new { v = 1, id = request?.Id, type = "error", code = ErrorCode(failure.Result) });
        }
        catch
        {
            // Exception strings can contain protocol payloads. Never send them to logs/UI.
            Emit(new { v = 1, id = request?.Id, type = "error", code = "connection" });
        }
        return 1;
    }

    private static async Task WatchParent(CancellationTokenSource lifetime)
    {
        try
        {
            // The client closes stdin or sends a cancellation line to end the operation.
            await Console.In.ReadLineAsync(lifetime.Token);
            await lifetime.CancelAsync();
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    /// A connected CM session with a callback pump; disposing disconnects and stops the pump.
    private sealed class Session : IAsyncDisposable
    {
        public SteamClient Client { get; }
        public SteamUser User { get; }
        private readonly CallbackManager manager;
        private readonly CancellationTokenSource pumpCancellation;
        private readonly Task pump;
        private readonly List<IDisposable> subscriptions = [];
        private readonly TaskCompletionSource connected = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<SteamUser.LoggedOnCallback> loggedOn = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource disconnected = new(TaskCreationOptions.RunContinuationsAsynchronously);

        /// Completes when Steam drops the connection after logon.
        public Task Disconnected => disconnected.Task;

        public Session(CancellationToken cancellation)
        {
            Client = new SteamClient(SteamConfiguration.Create(builder => builder
                .WithProtocolTypes(ProtocolTypes.WebSocket).WithConnectionTimeout(TimeSpan.FromSeconds(20))));
            manager = new CallbackManager(Client);
            User = Client.GetHandler<SteamUser>() ?? throw new ServiceFailure("protocol");
            subscriptions.Add(manager.Subscribe<SteamClient.ConnectedCallback>(_ => connected.TrySetResult()));
            subscriptions.Add(manager.Subscribe<SteamClient.DisconnectedCallback>(_ =>
            {
                connected.TrySetException(new ServiceFailure("connection"));
                loggedOn.TrySetException(new ServiceFailure("connection"));
                disconnected.TrySetResult();
            }));
            subscriptions.Add(manager.Subscribe<SteamUser.LoggedOnCallback>(callback => loggedOn.TrySetResult(callback)));
            pumpCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            var token = pumpCancellation.Token;
            pump = Task.Run(() =>
            {
                while (!token.IsCancellationRequested) manager.RunWaitCallbacks(TimeSpan.FromMilliseconds(50));
            }, CancellationToken.None);
        }

        public async Task ConnectAsync(CancellationToken cancellation)
        {
            Client.Connect();
            await connected.Task.WaitAsync(cancellation);
        }

        public async Task<SteamID> LogOnAsync(string accountName, string refreshToken, uint loginId, CancellationToken cancellation)
        {
            User.LogOn(new SteamUser.LogOnDetails { Username = accountName, AccessToken = refreshToken,
                LoginID = loginId, ShouldRememberPassword = true });
            var login = await loggedOn.Task.WaitAsync(cancellation);
            if (login.Result != EResult.OK) throw new ServiceFailure(ErrorCode(login.Result));
            return login.ClientSteamID ?? throw new ServiceFailure("protocol");
        }

        public async ValueTask DisposeAsync()
        {
            Client.Disconnect();
            await pumpCancellation.CancelAsync();
            await pump;
            subscriptions.ForEach(subscription => subscription.Dispose());
            pumpCancellation.Dispose();
        }
    }

    private static void ValidateStoredCredential(Request request)
    {
        if (string.IsNullOrWhiteSpace(request.AccountName) || request.RefreshToken is null
            || request.RefreshToken.Length is < 32 or > 16384)
            throw new ServiceFailure("protocol");
    }

    private static async Task Authenticate(Request request, CancellationToken cancellation)
    {
        await using var session = new Session(cancellation);
        var client = session.Client;
        Emit(new { v = 1, id = request.Id, type = "connecting" });
        await session.ConnectAsync(cancellation);
        string accountName;
        string refreshToken;
        if (request.Method == "qr")
        {
            var auth = await client.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails
            {
                DeviceFriendlyName = "Scena for macOS", IsPersistentSession = true, WebsiteID = "Client"
            }).WaitAsync(cancellation);
            void PublishChallenge() => Emit(new { v = 1, id = request.Id, type = "qr", challengeUrl = auth.ChallengeURL });
            auth.ChallengeURLChanged = PublishChallenge;
            PublishChallenge();
            var result = await auth.PollingWaitForResultAsync(cancellation);
            accountName = result.AccountName;
            refreshToken = result.RefreshToken;
            auth.ChallengeURLChanged = null;
        }
        else
        {
            ValidateStoredCredential(request);
            accountName = request.AccountName!;
            refreshToken = request.RefreshToken!;
        }
        Emit(new { v = 1, id = request.Id, type = "authorizing" });
        var steamId = await session.LogOnAsync(accountName, refreshToken, request.LoginId, cancellation);
        // CM-authenticated refresh supports SteamClient tokens. Handle token rotation.
        var tokens = await client.Authentication.GenerateAccessTokenForAppAsync(steamId, refreshToken, allowRenewal: true)
            .WaitAsync(cancellation);
        if (!string.IsNullOrEmpty(tokens.RefreshToken)) refreshToken = tokens.RefreshToken;
        var expiresAt = Expiration(tokens.AccessToken);
        Emit(new { v = 1, id = request.Id, type = "result", accountName,
            steamId = steamId.ConvertToUInt64().ToString(), refreshToken, accessToken = tokens.AccessToken, expiresAt });
    }

    private static long Expiration(string token)
    {
        var parts = token.Split('.');
        if (parts.Length != 3) throw new ServiceFailure("protocol");
        var payload = parts[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
        using var document = JsonDocument.Parse(Convert.FromBase64String(payload));
        return document.RootElement.GetProperty("exp").GetInt64();
    }

    private static string ErrorCode(EResult result) => result switch
    {
        EResult.InvalidPassword or EResult.Expired or EResult.Revoked or EResult.InvalidSignature => "credentialsExpired",
        EResult.AccountDisabled or EResult.AccountNotFound or EResult.Banned => "accountUnavailable",
        EResult.RateLimitExceeded or EResult.TryAnotherCM or EResult.Busy => "temporarilyUnavailable",
        EResult.AccessDenied => "accessDenied",
        _ => "connection"
    };
}
