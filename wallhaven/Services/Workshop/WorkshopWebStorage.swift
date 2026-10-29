import CryptoKit
import Foundation

/// 给不具备浏览器存储权限的沙盒网页提供按壁纸隔离的设置存储，不放宽 iframe 沙盒。
@MainActor
final class WorkshopWebStorage {
    static let limit = 256 * 1024
    private let defaults: UserDefaults
    private let key: String
    private(set) var values: [String: String]

    init(scope: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        key = "workshop.webStorage.v1." + hash
        values = defaults.data(forKey: key).flatMap { data in
            data.count <= Self.limit ? try? JSONDecoder().decode([String: String].self, from: data) : nil
        } ?? [:]
    }

    func apply(_ message: [String: Any]) {
        var next = values
        switch message["operation"] as? String {
        case "set":
            guard let name = message["key"] as? String, let value = message["value"] as? String else { return }
            next[name] = value
        case "remove":
            guard let name = message["key"] as? String else { return }
            next[name] = nil
        case "clear": next.removeAll()
        default: return
        }
        guard next.count <= 512, let data = try? JSONEncoder().encode(next), data.count <= Self.limit else { return }
        values = next
        defaults.set(data, forKey: key)
    }

    func script() -> String {
        let encoded = (try? JSONEncoder().encode(values))?.base64EncodedString() ?? "e30="
        return """
        (() => {
          if (!['wewall:', 'blob:', 'about:'].includes(location.protocol)) return;
          const seed = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0))));
          const post = message => { try { window.webkit.messageHandlers.host.postMessage(message); } catch (_) {} };
          function install(name, initial, persistent) {
            try { window[name].getItem('__scena_probe__'); return; } catch (_) {}
            const data = Object.assign(Object.create(null), initial);
            const emit = (operation, key, value) => {
              const message = {type:'webStorage', operation};
              if (key !== undefined) message.key = key;
              if (value !== undefined) message.value = value;
              if (persistent) post(message);
            };
            const methods = {
              getItem(key) { key = String(key); return Object.hasOwn(data, key) ? data[key] : null; },
              setItem(key, value) {
                key = String(key); value = String(value);
                const next = Object.assign(Object.create(null), data, {[key]:value});
                if (Object.keys(next).length > 512 || new TextEncoder().encode(JSON.stringify(next)).length > \(Self.limit))
                  throw new DOMException('Wallpaper storage quota exceeded', 'QuotaExceededError');
                data[key] = value; emit('set', key, value);
              },
              removeItem(key) { key = String(key); delete data[key]; emit('remove', key); },
              clear() { for (const key of Object.keys(data)) delete data[key]; emit('clear'); },
              key(index) { return Object.keys(data)[Number(index)] ?? null; }
            };
            const storage = new Proxy({}, {
              get(_, key) {
                if (key === Symbol.toStringTag) return 'Storage';
                if (key === 'length') return Object.keys(data).length;
                return Object.hasOwn(methods, key) ? methods[key] : data[key];
              },
              set(_, key, value) { methods.setItem(key, value); return true; },
              deleteProperty(_, key) { methods.removeItem(key); return true; },
              ownKeys() { return Object.keys(data); },
              getOwnPropertyDescriptor(_, key) {
                return Object.hasOwn(data, key) ? {configurable:true, enumerable:true, value:data[key], writable:true} : undefined;
              }
            });
            Object.defineProperty(window, name, {configurable:true, get:() => storage});
          }
          install('localStorage', seed, true);
          install('sessionStorage', {}, false);
          // 桌面层 WebKit 可能把失焦误当隐藏；可见性统一由原生窗口暂停策略控制。
          let hostVisible = true;
          Object.defineProperty(document, 'hidden', {configurable:true, get:() => !hostVisible});
          Object.defineProperty(document, 'visibilityState', {configurable:true, get:() => hostVisible ? 'visible' : 'hidden'});
          window.__scenaHostVisibility = value => {
            value = Boolean(value);
            if (value === hostVisible) return;
            hostVisible = value;
            document.dispatchEvent(new Event('visibilitychange'));
          };
          window.addEventListener('error', event => {
            if (event.message) post({type:'webRuntimeError', message:String(event.message).slice(0,500)});
          });
          window.addEventListener('unhandledrejection', event => post({type:'webRuntimeError', message:String(event.reason).slice(0,500)}));
          window.addEventListener('DOMContentLoaded', () => post({type:'webDocumentReady'}), {once:true});
        })();
        """
    }
}
