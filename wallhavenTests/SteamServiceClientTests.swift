import Darwin
import Foundation
import Testing
@testable import wallhaven

@MainActor
@Suite(.serialized)
struct SteamServiceClientTests {
    private func helper(mode: String) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("helper.py")
        let script = """
        #!/usr/bin/python3
        import json,os,signal,sys,time
        from pathlib import Path
        mode=\(String(reflecting: mode))
        Path(__file__).with_name('pid').write_text(str(os.getpid()))
        print(json.dumps({'v':1,'type':'ready'}),flush=True)
        request=json.loads(sys.stdin.readline())
        Path(__file__).with_name('args').write_text(json.dumps(sys.argv[1:]))
        if mode=='timeout':
            time.sleep(5)
        elif mode=='cancel':
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            time.sleep(10)
        elif mode=='malformed':
            print('not-json',flush=True)
            time.sleep(5)
        elif mode=='error':
            print(json.dumps({'v':1,'type':'error','id':request['id'],'code':'credentialsExpired','message':'DO_NOT_ECHO_THIS'}),flush=True)
        else:
            print(json.dumps({'v':1,'type':'qr','id':request['id'],'challengeUrl':'https://s.team/q/1/fixture'}),flush=True)
            payload={'v':1,'type':'result','id':request['id'],'accountName':'fixture','steamId':'76561198000000001','refreshToken':'a'*64,'accessToken':'A'*64,'expiresAt':time.time()+3600}
            if mode=='wrongID': payload['id']='other-request'
            if mode=='wrongVersion': payload['v']=2
            print(json.dumps(payload),flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (folder, executable)
    }

    @Test func privatePipeProtocolDeliversChallengeAndResultWithoutCredentialArguments() async throws {
        let (folder, executable) = try helper(mode: "success")
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = SteamServiceClient(executable: executable, timeout: 5)
        var challenges: [URL] = []
        let result = try await client.authenticate(.init(method: "qr", loginId: 42)) { challenges.append($0) }
        #expect(challenges.map(\.host) == ["s.team"])
        #expect(result.steamId == "76561198000000001")
        #expect(try String(contentsOf: folder.appendingPathComponent("args"), encoding: .utf8) == "[]")
    }

    @Test(arguments: ["malformed", "wrongID", "wrongVersion"])
    func malformedAndStaleResponsesCannotSucceed(_ mode: String) async throws {
        let (folder, executable) = try helper(mode: mode)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = SteamServiceClient(executable: executable, timeout: 3)
        await #expect(throws: SteamAuthenticationError.protocolFailure) {
            try await client.authenticate(.init(method: "qr", loginId: 42)) { _ in }
        }
    }

    @Test func helperErrorsAreMappedWithoutEchoingUntrustedPayloads() async throws {
        let (folder, executable) = try helper(mode: "error")
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = SteamServiceClient(executable: executable, timeout: 3)
        await #expect(throws: SteamAuthenticationError.credentialsExpired) {
            try await client.authenticate(.init(method: "restore", loginId: 42)) { _ in }
        }
    }

    @Test func helperTimeoutIsBounded() async throws {
        let (folder, executable) = try helper(mode: "timeout")
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = SteamServiceClient(executable: executable, timeout: 0.2)
        await #expect(throws: SteamAuthenticationError.timeout) {
            try await client.authenticate(.init(method: "qr", loginId: 42)) { _ in }
        }
    }

    @Test func cancellationClosesEvenAHelperIgnoringTerminate() async throws {
        let (folder, executable) = try helper(mode: "cancel")
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = SteamServiceClient(executable: executable, timeout: 5)
        let task = Task { try await client.authenticate(.init(method: "qr", loginId: 42)) { _ in } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("args").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<150 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(pid, 0) != 0)
    }
}
