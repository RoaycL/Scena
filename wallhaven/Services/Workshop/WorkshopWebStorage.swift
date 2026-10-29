import CryptoKit
import Foundation

/// 给不具备浏览器存储权限的沙盒网页提供按壁纸隔离的设置存储，不放宽 iframe 沙盒。
/// 每个壁纸一个 JSON 文件（最多 256 KiB）。不放进偏好设置：壁纸多了会让偏好文件变大、拖慢启动
@MainActor
final class WorkshopWebStorage {
    static let limit = 256 * 1024
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.roayc.wallhaven/WorkshopWebStorage", isDirectory: true)
    private let file: URL
    private(set) var values: [String: String]

    /// defaults：1.0.35 及更早版本把设置存在偏好设置里，读到后迁移到文件并删除原记录
    init(scope: String, defaults: UserDefaults = .standard, directory: URL = WorkshopWebStorage.defaultDirectory) {
        let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent(hash + ".json")
        var data = try? Data(contentsOf: file)
        let legacyKey = "workshop.webStorage.v1." + hash
        if let legacy = defaults.data(forKey: legacyKey) {
            if data == nil {
                data = legacy
                Self.write(legacy, to: file)
            }
            defaults.removeObject(forKey: legacyKey)
        }
        values = data.flatMap { data in
            data.count <= Self.limit ? try? JSONDecoder().decode([String: String].self, from: data) : nil
        } ?? [:]
    }

    private static func write(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
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
        guard next != values else { return }
        values = next
        if next.isEmpty { try? FileManager.default.removeItem(at: file) } else { Self.write(data, to: file) }
    }

    func script() -> String {
        let encoded = (try? JSONEncoder().encode(values))?.base64EncodedString() ?? "e30="
        return """
        (() => {
          if (!['wewall:', 'blob:', 'about:'].includes(location.protocol)) return;
          const seed = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0))));
          const post = message => { try { window.webkit.messageHandlers.host.postMessage(message); } catch (_) {} };
          // 兼容桥稍后会接管页面的帧回调和定时器（暂停时扣住）；视频层刷新要用原始版本
          const nativeFrame = window.requestAnimationFrame.bind(window);
          const nativeTimeout = window.setTimeout.bind(window);
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
          // WebKit 的视频画面是单独合成的一层，框只在视频元素几何变化时重算。
          // 若在视频还没读到尺寸、或页面暂时不可见时算错了框（16:9 画面被塞进 2:1 的框），
          // 而作者布局始终全屏不变，这一层就会一直错位。这里把 object-position 偏移 1/32 像素
          // （低于屏幕像素精度，看不出移动）保持两帧再还原作者样式，迫使 WebKit 按当前布局重算
          const refreshing = new WeakSet();
          const refreshVideo = video => {
            if (!(video instanceof HTMLVideoElement) || !video.isConnected || !video.videoWidth || refreshing.has(video)) return;
            refreshing.add(video);
            const inline = video.style.getPropertyValue('object-position');
            const priority = video.style.getPropertyPriority('object-position');
            const [x = '50%', y = '50%'] = getComputedStyle(video).objectPosition.split(' ');
            video.style.setProperty('object-position', `calc(${x} + 0.03125px) ${y}`, 'important');
            void video.offsetWidth;
            const restore = () => {
              if (inline) video.style.setProperty('object-position', inline, priority);
              else video.style.removeProperty('object-position');
              refreshing.delete(video);
            };
            // 不可见时帧回调不会触发，用定时器兜底还原
            let done = false;
            const finish = () => { if (!done) { done = true; restore(); } };
            nativeFrame(() => nativeFrame(finish));
            nativeTimeout(finish, 250);
          };
          const refreshAllVideos = () => document.querySelectorAll('video').forEach(refreshVideo);
          for (const type of ['loadedmetadata', 'resize', 'playing']) {
            document.addEventListener(type, event => refreshVideo(event.target), true);
          }
          window.addEventListener('resize', refreshAllVideos);
          window.__scenaRefreshMedia = refreshAllVideos;
          // 兜底：错位的起因不总能捕获到，可见期间定期刷新，最迟几秒内恢复
          const periodic = () => { if (hostVisible) refreshAllVideos(); nativeTimeout(periodic, 3000); };
          nativeTimeout(periodic, 3000);

          window.__scenaHostVisibility = value => {
            value = Boolean(value);
            if (value) nativeTimeout(refreshAllVideos, 0);
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
