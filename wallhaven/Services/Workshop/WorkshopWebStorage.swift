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
          // WebKit 的视频画面是单独的原生层。视频在隐藏状态（透明度为 0）下加载后再显示出来，
          // 这一层可能沿用读到尺寸之前的默认大小（300×150）：16:9 画面被画进贴顶的 2:1 区域，右侧和底部露出底图。
          // 改样式、隐藏再显示、调整窗口尺寸都纠正不了，只有重新创建元素的渲染对象才会按真实尺寸重建这一层。
          // 所以视频的显示状态（class / style、过渡动画、片源）变化停下来后，把可见的视频原地重新插入；
          // 同步插回不会暂停播放
          const pending = new Set();
          let pendingTimer = 0;
          let observer = null;
          const rebuildVideoLayer = video => {
            if (!(video instanceof HTMLVideoElement) || !video.isConnected || !video.videoWidth) return;
            if (Number(getComputedStyle(video).opacity) === 0) return;
            const playing = !video.paused;
            // 插回原位时 WebKit 会当作无事发生，必须先移除
            const parent = video.parentNode, next = video.nextSibling;
            parent.removeChild(video);
            parent.insertBefore(video, next);
            // 丢掉自己这次插入产生的变化记录，避免反复重建
            observer?.takeRecords();
            if (playing && video.paused) video.play().catch(() => {});
          };
          const schedule = video => {
            pending.add(video);
            clearTimeout(pendingTimer);
            pendingTimer = setTimeout(() => {
              const videos = [...pending];
              pending.clear();
              videos.forEach(rebuildVideoLayer);
            }, 150);
          };
          observer = new MutationObserver(records => {
            for (const record of records) {
              if (record.type === 'attributes') {
                if (record.target instanceof HTMLVideoElement) schedule(record.target);
                continue;
              }
              for (const node of record.addedNodes) {
                if (node instanceof HTMLVideoElement) schedule(node);
                else if (node instanceof Element) node.querySelectorAll('video').forEach(schedule);
              }
            }
          });
          const observe = () => observer.observe(document.documentElement,
            {subtree:true, childList:true, attributes:true, attributeFilter:['class', 'style', 'id', 'hidden']});
          if (document.documentElement) observe(); else document.addEventListener('DOMContentLoaded', observe, {once:true});
          for (const type of ['loadedmetadata', 'resize', 'playing', 'transitionend', 'animationend']) {
            document.addEventListener(type, event => event.target instanceof HTMLVideoElement && schedule(event.target), true);
          }
          window.__scenaRefreshMedia = () => document.querySelectorAll('video').forEach(schedule);

          window.__scenaHostVisibility = value => {
            value = Boolean(value);
            if (value === hostVisible) return;
            hostVisible = value;
            document.dispatchEvent(new Event('visibilitychange'));
          };

          // 桌面上的鼠标操作：壁纸窗口留在图标下面、不接收鼠标时，由宿主把点按、拖拽、滚轮转成页面事件。
          // 合成事件的 isTrusted 为 false，不会触发 :hover 样式，也不能解锁需要真实点击的功能（如有声播放）
          let hovered = null, pressed = null, suppressMouse = false;
          const pointerInit = (x, y, buttons) => ({bubbles:true, cancelable:true, composed:true, view:window,
            clientX:x, clientY:y, screenX:x, screenY:y, button:0, buttons,
            pointerId:1, pointerType:'mouse', isPrimary:true, width:1, height:1, pressure:buttons ? 0.5 : 0});
          // pointerdown 被取消后，浏览器在这次按下期间不再派发兼容的 mouse 事件（click 照常）
          const fire = (target, pointerType, mouseType, init) => {
            if (!target.dispatchEvent(new PointerEvent(pointerType, init)) && pointerType === 'pointerdown') suppressMouse = true;
            if (!suppressMouse) target.dispatchEvent(new MouseEvent(mouseType, init));
          };
          const crossing = (target, prefix, init, related) => {
            fire(target, `pointer${prefix === 'enter' ? 'over' : 'out'}`, `mouse${prefix === 'enter' ? 'over' : 'out'}`, {...init, relatedTarget:related});
            const flat = {...init, bubbles:false, relatedTarget:related};
            target.dispatchEvent(new PointerEvent(`pointer${prefix}`, flat));
            target.dispatchEvent(new MouseEvent(`mouse${prefix}`, flat));
          };
          const hover = (target, init) => {
            if (target === hovered) return;
            const previous = hovered;
            hovered = target;
            if (previous?.isConnected) crossing(previous, 'leave', init, target);
            if (target) crossing(target, 'enter', init, previous);
          };
          const scrollable = (element, dx, dy) => {
            for (let node = element; node && node !== document.documentElement; node = node.parentElement) {
              const style = getComputedStyle(node);
              if (dy && /auto|scroll/.test(style.overflowY) && node.scrollHeight > node.clientHeight) return node;
              if (dx && /auto|scroll/.test(style.overflowX) && node.scrollWidth > node.clientWidth) return node;
            }
            return document.scrollingElement;
          };
          window.__scenaPointer = (kind, x, y, dx, dy) => {
            const target = kind === 'leave' ? null : (document.elementFromPoint(x, y) ?? document.documentElement);
            // 外层播放页：壁纸在全屏 iframe 里，交给 iframe 内的文档处理
            if (target instanceof HTMLIFrameElement) return;
            const init = pointerInit(x, y, kind === 'down' || (kind === 'move' && pressed) ? 1 : 0);
            hover(target, init);
            if (!target) { pressed = null; suppressMouse = false; return; }
            if (kind === 'move') {
              fire(target, 'pointermove', 'mousemove', init);
            } else if (kind === 'down') {
              pressed = target;
              suppressMouse = false;
              fire(target, 'pointerdown', 'mousedown', init);
              target.closest('input,textarea,select,button,a[href],[tabindex]')?.focus?.({preventScroll:true});
            } else if (kind === 'up') {
              fire(target, 'pointerup', 'mouseup', init);
              // click 派发给按下和松开位置的最近公共祖先
              let common = pressed;
              while (common && !common.contains(target)) common = common.parentElement;
              if (common) common.dispatchEvent(new MouseEvent('click', init));
              pressed = null;
              suppressMouse = false;
            } else if (kind === 'wheel') {
              if (target.dispatchEvent(new WheelEvent('wheel', {...init, deltaX:dx, deltaY:dy, deltaMode:0})))
                scrollable(target, dx, dy)?.scrollBy(dx, dy);
            }
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
