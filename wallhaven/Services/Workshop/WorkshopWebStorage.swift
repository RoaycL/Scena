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
          // WebKit 的视频画面是单独的原生层，大小在元素的渲染对象创建时确定，之后只在少数情况下更新：
          // 视频在读到尺寸之前就有了渲染对象（尤其在透明度为 0 时加载、再显示出来），会一直沿用默认的 300×150，
          // 16:9 画面被画进贴顶的 2:1 区域；窗口缩放后也可能停在旧尺寸。改样式、隐藏再显示都纠正不了，
          // 只有把元素移出 DOM 再插回、重新创建渲染对象才会按真实尺寸重建这一层（插回原位会被当作无操作）。
          // 每个片源在解码出第一帧、第一次开始播放时各重建一次（WebM 的画面层尺寸在第一帧之后才确定）；
          // 换片的页面这时通常还没把它显示出来，看不出变化。暂停后恢复播放不重建：反复重建会让后台播放卡顿。
          // 正在显示的视频换片源时，新片源的头几帧可能画在旧框里（看起来是画面先小后大的缩放）：
          // 换片时先隐藏视频，解码出第一帧并重建后立即显示。新片源没有画面前，视频元素本来就是透明的，
          // 露出的是页面垫在下面的内容，所以隐藏不会比页面原本多露出什么（1.0.40 等到开始播放才显示，会多露出封面）。
          // 不能用 canvas.drawImage 定格画面：WebKit 取视频帧要同步等 GPU 进程，视频没出帧时会一直等，冻住所有网页。
          // 元素尺寸真的变化（窗口缩放）后，等变化停下来再重建可见的视频。同步插回不会暂停播放
          const rebuildVideoLayer = video => {
            if (!(video instanceof HTMLVideoElement) || !video.isConnected) return;
            const playing = !video.paused;
            const parent = video.parentNode, next = video.nextSibling;
            parent.removeChild(video);
            parent.insertBefore(video, next);
            if (playing && video.paused) video.play().catch(() => {});
          };
          const concealed = new Map();
          const reveal = video => {
            const timer = concealed.get(video);
            if (timer === undefined) return;
            clearTimeout(timer);
            concealed.delete(video);
            video.style.removeProperty('visibility');
          };
          const conceal = video => {
            if (concealed.has(video) || video.style.getPropertyValue('visibility') || !video.isConnected) return;
            const style = getComputedStyle(video);
            if (Number(style.opacity) === 0 || style.visibility === 'hidden') return;
            video.style.setProperty('visibility', 'hidden', 'important');
            // 兜底：页面不加载这个片源时也要恢复
            concealed.set(video, setTimeout(() => reveal(video), 3000));
          };
          // 页面换片源的入口：在新片源开始加载之前隐藏
          const srcProperty = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
          if (srcProperty?.set) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {...srcProperty, set(value) {
              if (this instanceof HTMLVideoElement) conceal(this);
              srcProperty.set.call(this, value);
            }});
          }
          const nativeLoad = HTMLMediaElement.prototype.load;
          HTMLMediaElement.prototype.load = function () {
            if (this instanceof HTMLVideoElement) conceal(this);
            return nativeLoad.call(this);
          };
          const nativeSetAttribute = Element.prototype.setAttribute;
          Element.prototype.setAttribute = function (name, value) {
            if (this instanceof HTMLVideoElement && String(name).toLowerCase() === 'src') conceal(this);
            return nativeSetAttribute.call(this, name, value);
          };
          const rebuiltStages = new WeakMap();
          const rebuildOncePerSource = (video, stage) => {
            const done = rebuiltStages.get(video);
            if (done?.src !== video.currentSrc) rebuiltStages.set(video, {src: video.currentSrc, stages: new Set([stage])});
            else if (done.stages.has(stage)) return;
            else done.stages.add(stage);
            rebuildVideoLayer(video);
            // 第一帧到达、开始播放时布局可能还没按真实尺寸更新，WebKit 会在这次重建里按默认的 2:1 框创建画面层，
            // 之后只改外框、不改画面。布局稳定后再重建一次：第一帧时视频通常还没显示；开始播放时只重建仍在显示的
            const src = video.currentSrc;
            setTimeout(() => {
              if (video.currentSrc !== src || !video.videoWidth) return;
              if (stage === 'playing' && (video.paused || !isShown(video))) return;
              rebuildVideoLayer(video);
            }, stage === 'playing' ? 1000 : 500);
          };
          const isShown = video => {
            const style = getComputedStyle(video);
            return Number(style.opacity) > 0 && style.visibility !== 'hidden';
          };
          const pending = new Set();
          let pendingTimer = 0;
          const schedule = video => {
            pending.add(video);
            clearTimeout(pendingTimer);
            pendingTimer = setTimeout(() => {
              const videos = [...pending];
              pending.clear();
              for (const video of videos) {
                if (video.videoWidth && Number(getComputedStyle(video).opacity) > 0) rebuildVideoLayer(video);
              }
            }, 200);
          };
          const scheduleAll = () => document.querySelectorAll('video').forEach(schedule);
          // 元素尺寸变化（含窗口缩放引起的）；首次观察时的回调跳过
          const sized = new WeakMap();
          const resizeObserver = new ResizeObserver(entries => {
            for (const entry of entries) {
              const size = `${Math.round(entry.contentRect.width)}x${Math.round(entry.contentRect.height)}`;
              const previous = sized.get(entry.target);
              sized.set(entry.target, size);
              if (previous && previous !== size) schedule(entry.target);
            }
          });
          for (const type of ['loadeddata', 'playing']) {
            document.addEventListener(type, event => {
              const video = event.target;
              if (!(video instanceof HTMLVideoElement)) return;
              rebuildOncePerSource(video, type);
              resizeObserver.observe(video);
              if (type === 'loadeddata') reveal(video);
            }, true);
          }
          document.addEventListener('loadstart', event => {
            const video = event.target;
            if (video instanceof HTMLVideoElement && video.isConnected) conceal(video);
          }, true);
          window.__scenaRefreshMedia = scheduleAll;

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
