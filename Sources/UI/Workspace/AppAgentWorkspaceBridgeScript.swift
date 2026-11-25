import Foundation

/// 注入工作区页面的脚本。两个命名空间按能力的提供方分开：
/// - `window.appAgent.workspace`：AppAgent 提供，只管本页（状态、触摸区域、布局事件）；
/// - `window.hostApp.invoke`：宿主提供的动作（打开页面、算路…），宿主决定放行哪些。
/// 绝不转发到宿主的通用 JS/NA bridge。
enum AppAgentWorkspaceBridgeScript {

    /// 原生收消息的 handler 名。
    static let messageHandlerName = "appAgentWorkspace"

    /// 单条页面状态（key + value）的上限，整份状态另有 `SessionWorkspaceLimits.maximumStateBytes`。
    static let maximumStateBytes = SessionWorkspaceLimits.maximumStateBytes

    static func source(documentID: String, state: [String: String]) throws -> String {
        let initialState = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let document = String(decoding: try JSONEncoder().encode(documentID), as: UTF8.self)
        return """
        (() => {
            "use strict";
            const documentID = \(document);
            let state = \(initialState);
            let layout = null;
            let revision = 0;
            let scheduled = false;
            let motions = 0;
            // 页面不在前台时写的状态先攒着，回到前台再交给原生。
            let pendingState = {};
            let reportedErrors = 0;
            // 页面一旦自己调用 setTouchRegions 就接管区域，自动模式停止；useAutoTouchRegions 交还。
            let manual = false;
            function post(body) {
                window.webkit.messageHandlers.\(messageHandlerName).postMessage(Object.assign({documentID}, body));
            }
            function postRegions(rects, blocks, polygons) {
                if (!layout || !layout.active || !layout.hasSlot) {
                    return false;
                }
                const viewport = window.visualViewport;
                const shifted = viewport && (viewport.offsetLeft !== 0 || viewport.offsetTop !== 0
                    || Math.abs(viewport.scale - 1) > 0.01);
                // 手动模式由页面负责：动画中报的区域照常生效，页面自己决定何时更新。
                const revoke = shifted || (!manual && motions > 0);
                post({
                    type: "setTouchRegions",
                    epoch: layout.epoch,
                    revision: ++revision,
                    viewport: {width: window.innerWidth, height: window.innerHeight},
                    mode: manual ? "manual" : "auto",
                    rects: revoke ? [] : rects,
                    polygons: revoke ? [] : (polygons || []),
                    blocks: revoke ? [] : blocks
                });
                return true;
            }
            // 每项是矩形 [x, y, w, h] 或多边形 {points: [[x, y], ...]}；格式不对的整批由原生拒绝。
            function setTouchRegions(regions) {
                manual = true;
                const rects = [];
                const polygons = [];
                for (const region of Array.isArray(regions) ? regions : [regions]) {
                    if (region && !Array.isArray(region) && Array.isArray(region.points)) {
                        polygons.push(region.points);
                    } else {
                        rects.push(region);
                    }
                }
                return postRegions(rects, [], polygons);
            }
            function useAutoTouchRegions() {
                manual = false;
                postRegions([], []);
                announceLayout();
                return Boolean(layout && layout.active && layout.hasSlot);
            }
            function transparentColor(value) {
                if (!value || value === "transparent") {
                    return true;
                }
                const match = /^rgba?\\(([^)]*)\\)$/.exec(value);
                if (!match) {
                    return false;
                }
                const parts = match[1].split(/[\\s,\\/]+/).filter(part => part.length > 0);
                return parts.length === 4 && parseFloat(parts[3]) === 0;
            }
            function paintsBorder(style) {
                for (const side of ["Top", "Right", "Bottom", "Left"]) {
                    if (parseFloat(style["border" + side + "Width"]) > 0
                        && style["border" + side + "Style"] !== "none"
                        && !transparentColor(style["border" + side + "Color"])) {
                        return true;
                    }
                }
                return false;
            }
            function hasOwnText(element) {
                for (const node of element.childNodes) {
                    if (node.nodeType === Node.TEXT_NODE && node.textContent.trim().length > 0) {
                        return true;
                    }
                }
                return false;
            }
            const contentTags = /^(IMG|SVG|CANVAS|VIDEO|INPUT|BUTTON|TEXTAREA|SELECT|IFRAME|A|LABEL|PICTURE)$/;
            function blocksTouch(element, style) {
                if (style.pointerEvents === "none" || style.visibility !== "visible") {
                    return false;
                }
                if (contentTags.test(element.tagName.toUpperCase())) {
                    return true;
                }
                if (!transparentColor(style.backgroundColor) || style.backgroundImage !== "none"
                    || style.boxShadow !== "none" || paintsBorder(style)) {
                    return true;
                }
                const scrolls = /(auto|scroll)/.test(style.overflowX + style.overflowY)
                    && (element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth);
                return scrolls || hasOwnText(element);
            }
            function overlaps(a, b) {
                return a[0] <= b[0] + b[2] + 4 && b[0] <= a[0] + a[2] + 4
                    && a[1] <= b[1] + b[3] + 4 && b[1] <= a[1] + a[3] + 4;
            }
            function union(a, b) {
                const left = Math.min(a[0], b[0]);
                const top = Math.min(a[1], b[1]);
                const right = Math.max(a[0] + a[2], b[0] + b[2]);
                const bottom = Math.max(a[1] + a[3], b[1] + b[3]);
                return [left, top, right - left, bottom - top];
            }
            // 重叠或相距 4px 内的合并；仍超过 64 个就按纵向顺序分组取外框。只会多挡，不会少挡。
            function mergeBlocks(rects) {
                let merged = rects.slice();
                let changedAny = true;
                while (changedAny && merged.length > 1) {
                    changedAny = false;
                    const next = [];
                    for (const rect of merged) {
                        const index = next.findIndex(other => overlaps(rect, other));
                        if (index >= 0) {
                            next[index] = union(next[index], rect);
                            changedAny = true;
                        } else {
                            next.push(rect);
                        }
                    }
                    merged = next;
                }
                if (merged.length <= 64) {
                    return merged;
                }
                merged.sort((a, b) => a[1] - b[1]);
                const size = Math.ceil(merged.length / 64);
                const grouped = [];
                for (let i = 0; i < merged.length; i += size) {
                    grouped.push(merged.slice(i, i + size).reduce(union));
                }
                return grouped;
            }
            // 默认穿透：只把网页的透明处交给底图，画了东西的元素照常可点。
            // 元素太多（超过 3000）时不穿透，宁可插槽视图拖不动也不误把点击送下去。
            function autoReport() {
                if (manual || !layout || !layout.active || !layout.hasSlot || !document.body) {
                    return;
                }
                const width = window.innerWidth;
                const height = window.innerHeight;
                const blocks = [];
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT, {
                    acceptNode(node) {
                        const style = getComputedStyle(node);
                        if (style.display === "none" || parseFloat(style.opacity) === 0) {
                            return NodeFilter.FILTER_REJECT;
                        }
                        return NodeFilter.FILTER_ACCEPT;
                    }
                });
                let count = 0;
                for (let element = walker.nextNode(); element; element = walker.nextNode()) {
                    count += 1;
                    if (count > 3000) {
                        postRegions([], []);
                        return;
                    }
                    if (!blocksTouch(element, getComputedStyle(element))) {
                        continue;
                    }
                    const box = element.getBoundingClientRect();
                    const left = Math.max(0, box.left);
                    const top = Math.max(0, box.top);
                    const right = Math.min(width, box.right);
                    const bottom = Math.min(height, box.bottom);
                    if (right > left && bottom > top) {
                        blocks.push([left, top, right - left, bottom - top]);
                    }
                }
                postRegions([[0, 0, width, height]], mergeBlocks(blocks));
            }
            function announceLayout() {
                if (layout && layout.active) {
                    window.dispatchEvent(new CustomEvent("appagent:layout", {detail: {...layout}}));
                    autoReport();
                }
            }
            function flushState() {
                if (!layout || !layout.active) {
                    return;
                }
                for (const key of Object.keys(pendingState)) {
                    post({type: "setState", key, value: pendingState[key]});
                }
                pendingState = {};
            }
            function stateBytes(object) {
                let total = 0;
                for (const key of Object.keys(object)) {
                    total += new TextEncoder().encode(key + object[key]).length;
                }
                return total;
            }
            // value 为 null 表示删掉这个 key；其余必须是字符串，对象请先 JSON.stringify。
            function setState(key, value) {
                if (typeof key !== "string" || key.length === 0) {
                    throw new TypeError("state key must be a nonempty string");
                }
                if (value !== null && typeof value !== "string") {
                    throw new TypeError("state value must be a string or null");
                }
                const next = Object.assign({}, state);
                if (value === null) {
                    delete next[key];
                } else {
                    next[key] = value;
                }
                if (stateBytes(next) > \(maximumStateBytes)) {
                    throw new RangeError("workspace state exceeds 128 KiB");
                }
                state = next;
                pendingState[key] = value;
                flushState();
            }
            function reportError(message) {
                if (reportedErrors >= 20) {
                    return;
                }
                reportedErrors += 1;
                post({type: "error", message: String(message).slice(0, 500)});
            }
            window.addEventListener("error", event => {
                reportError(event.message || "script error");
            });
            window.addEventListener("unhandledrejection", event => {
                reportError("unhandled rejection: " + (event.reason && event.reason.message || event.reason));
            });
            function scheduleLayout() {
                if (!scheduled) {
                    scheduled = true;
                    requestAnimationFrame(() => {
                        scheduled = false;
                        announceLayout();
                    });
                }
            }
            // 视口变了，坐标全部失效：两种模式都撤销，下一帧重新上报。
            function geometryChanged() {
                postRegions([], []);
                scheduleLayout();
            }
            // 页面内容变了：自动模式撤销后重新测量；手动模式保留页面报的区域，只发布局事件让页面按需更新。
            function contentChanged() {
                if (!manual) {
                    postRegions([], []);
                }
                scheduleLayout();
            }
            // 页面按钮调宿主动作：只认用户点击触发的调用，同一时间只跑一个，结果由原生回填。
            let invokeSeq = 0;
            let pendingInvoke = null;
            function invoke(tool, args) {
                if (pendingInvoke) {
                    return Promise.resolve({ok: false, error: "another invoke is running"});
                }
                const activation = navigator.userActivation;
                if (activation && !activation.isActive) {
                    return Promise.resolve({ok: false, error: "invoke must be called from a user tap"});
                }
                let payload;
                try {
                    payload = JSON.parse(JSON.stringify(args === undefined ? {} : args));
                } catch (error) {
                    return Promise.resolve({ok: false, error: "invoke args must be JSON"});
                }
                if (typeof tool !== "string" || !payload || typeof payload !== "object" || Array.isArray(payload)) {
                    return Promise.resolve({ok: false, error: "invoke needs a tool name and an args object"});
                }
                const callID = ++invokeSeq;
                return new Promise(resolve => {
                    pendingInvoke = {callID, resolve};
                    post({type: "invoke", callID, tool, args: payload});
                });
            }
            Object.defineProperty(window, "appAgent", {
                value: Object.freeze({
                    workspace: Object.freeze({
                        get state() {
                            return Object.assign({}, state);
                        },
                        setState,
                        setTouchRegions,
                        useAutoTouchRegions
                    })
                }),
                writable: false,
                configurable: false
            });
            Object.defineProperty(window, "hostApp", {
                value: Object.freeze({invoke}),
                writable: false,
                configurable: false
            });
            Object.defineProperty(window, "__appAgentInvokeResult", {
                value: (callID, result) => {
                    if (!pendingInvoke || pendingInvoke.callID !== callID) {
                        return;
                    }
                    const resolve = pendingInvoke.resolve;
                    pendingInvoke = null;
                    resolve(result);
                },
                writable: false,
                configurable: false
            });
            Object.defineProperty(window, "__appAgentWorkspaceLayout", {
                value: value => {
                    layout = value;
                    flushState();
                    postRegions([], []);
                    announceLayout();
                },
                writable: false,
                configurable: false
            });
            // 模型经 set_state 改了状态：整份替换，页面收 appagent:state 事件按新数据刷新，不重新加载。
            Object.defineProperty(window, "__appAgentWorkspaceState", {
                value: next => {
                    state = Object.assign({}, next);
                    window.dispatchEvent(new CustomEvent("appagent:state", {detail: Object.assign({}, state)}));
                },
                writable: false,
                configurable: false
            });
            window.addEventListener("resize", geometryChanged);
            window.addEventListener("scroll", contentChanged, true);
            if (window.visualViewport) {
                window.visualViewport.addEventListener("resize", geometryChanged);
                window.visualViewport.addEventListener("scroll", geometryChanged);
            }
            for (const name of ["transitionrun", "animationstart"]) {
                document.addEventListener(name, () => {
                    motions += 1;
                    contentChanged();
                }, true);
            }
            for (const name of ["transitionend", "transitioncancel", "animationend", "animationcancel"]) {
                document.addEventListener(name, () => {
                    motions = Math.max(0, motions - 1);
                    contentChanged();
                }, true);
            }
            document.addEventListener("DOMContentLoaded", () => {
                const observer = new MutationObserver(contentChanged);
                observer.observe(document.documentElement, {
                    subtree: true, childList: true, attributes: true, characterData: true
                });
                new ResizeObserver(contentChanged).observe(document.documentElement);
                post({type: "ready"});
            }, {once: true});
        })();
        """
    }
}
