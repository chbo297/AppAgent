import Foundation
import CoreGraphics

/// Workspace 页的 UI 分配策略：决定"页面上的区域/事件归谁"（H5 还是宿主放进来的插槽视图）。
/// 目前唯一裁决项是触摸命中（.touch）；后续新增 UI/业务裁决时往 `WorkspaceUIEvent` 加 case，
/// 不改本类的既有裁决逻辑。
/// 与 UIKit/JS 解耦；旧 epoch、倒序 revision、非有限坐标一律撤销命中资格。
/// regions / polygons 是交给插槽视图的区域（矩形与多边形，合计最多 64 个），
/// blocks 是其中仍由网页接收的元素区域（自动穿透模式下由页面脚本测量）。
struct AppAgentWorkspaceUIPolicy {
    /// Workspace 页上的 UI 事件种类。每类事件的裁决互不越界。
    enum Event {
        /// 一次触摸落在页面上，需要裁决交给 H5 还是插槽视图。
        case touch(point: CGPoint, size: CGSize, occlusions: [CGRect])
    }

    /// 裁决结果。
    enum Resolution {
        /// 交给 H5（WebView）处理。
        case web

        /// 穿透给宿主放进来的插槽视图。
        case slot
    }

    static let maximumRegions = 64
    static let maximumPolygonPoints = 256

    private(set) var epoch = 0
    private(set) var revision = 0
    private(set) var regions: [CGRect] = []
    private(set) var polygons: [[CGPoint]] = []
    private(set) var blocks: [CGRect] = []
    private(set) var nativeSize = CGSize.zero

    /// 事件裁决唯一入口：新增事件种类时在此分发到对应的私有裁决方法。
    func resolve(_ event: Event) -> Resolution {
        switch event {
        case let .touch(point, size, occlusions):
            return resolvesTouch(point: point, size: size, occlusions: occlusions) ? .slot : .web
        }
    }

    mutating func invalidate(size: CGSize) {
        epoch += 1
        revision = 0
        nativeSize = size
        regions = []
        polygons = []
        blocks = []
    }

    mutating func accept(epoch: Int, revision: Int, viewport: CGSize, rects: [CGRect],
                         polygons: [[CGPoint]] = [], blocks: [CGRect] = []) -> Bool {
        regions = []
        self.polygons = []
        self.blocks = []
        guard epoch == self.epoch, revision > self.revision,
              revision <= 9_007_199_254_740_991,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              nativeSize.width.isFinite, nativeSize.height.isFinite,
              nativeSize.width > 0, nativeSize.height > 0,
              rects.count + polygons.count <= Self.maximumRegions,
              blocks.count <= Self.maximumRegions else {
            return false
        }
        let sx = nativeSize.width / viewport.width
        let sy = nativeSize.height / viewport.height
        guard sx.isFinite, sy.isFinite, abs(sx / sy - 1) <= 0.03 else {
            return false
        }
        guard let converted = Self.convert(rects, viewport: viewport, sx: sx, sy: sy),
              let convertedPolygons = Self.convert(polygons, viewport: viewport, sx: sx, sy: sy),
              let convertedBlocks = Self.convert(blocks, viewport: viewport, sx: sx, sy: sy) else {
            return false
        }
        self.revision = revision
        regions = converted
        self.polygons = convertedPolygons
        self.blocks = convertedBlocks
        return true
    }

    /// 多边形每个顶点都必须在视口内（含边），3~256 个点。
    private static func convert(_ polygons: [[CGPoint]], viewport: CGSize,
                                sx: CGFloat, sy: CGFloat) -> [[CGPoint]]? {
        var converted: [[CGPoint]] = []
        for polygon in polygons {
            guard (3...maximumPolygonPoints).contains(polygon.count) else {
                return nil
            }
            var points: [CGPoint] = []
            for point in polygon {
                guard point.x.isFinite, point.y.isFinite,
                      point.x >= 0, point.y >= 0,
                      point.x <= viewport.width, point.y <= viewport.height else {
                    return nil
                }
                points.append(CGPoint(x: point.x * sx, y: point.y * sy))
            }
            converted.append(points)
        }
        return converted
    }

    private static func convert(_ rects: [CGRect], viewport: CGSize, sx: CGFloat, sy: CGFloat) -> [CGRect]? {
        var converted: [CGRect] = []
        for rect in rects {
            let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
            guard values.allSatisfy({ value in
                value.isFinite
            }),
                  rect.size.width > 0,
                  rect.size.height > 0,
                  rect.minX >= 0, rect.minY >= 0,
                  rect.maxX <= viewport.width, rect.maxY <= viewport.height else {
                return nil
            }
            converted.append(CGRect(x: rect.minX * sx, y: rect.minY * sy,
                                    width: rect.width * sx, height: rect.height * sy))
        }
        return converted
    }

    /// 触摸裁决：区域内且不在遮挡/元素块里 → 交给插槽视图；否则 H5。
    private func resolvesTouch(point: CGPoint, size: CGSize, occlusions: [CGRect]) -> Bool {
        guard size == nativeSize else {
            return false
        }
        guard !(occlusions + blocks).contains(where: { rect in
            rect.contains(point)
        }) else {
            return false
        }
        return regions.contains { rect in
            rect.contains(point)
        } || polygons.contains { polygon in
            Self.polygon(polygon, contains: point)
        }
    }

    /// 偶奇规则射线法；自交多边形按偶奇填充理解。
    private static func polygon(_ points: [CGPoint], contains point: CGPoint) -> Bool {
        var inside = false
        var previous = points[points.count - 1]
        for current in points {
            if (current.y > point.y) != (previous.y > point.y) {
                let crossX = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < crossX {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }
}

