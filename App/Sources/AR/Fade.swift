import RealityKit

/// 透明度を変える。iOS 18 からは OpacityComponent（子にも掛け算で効く）。
/// iOS 17 には OpacityComponent が無いので、同じ見え方になるよう、質感（material）の透明度を直接変える：
/// 親から子まで「自分の透明度」を掛け合わせ、元の質感の透明度に掛けて置き換える（見えない壁 OcclusionMaterial はそのまま）。
@MainActor
enum Fade {
    static func set(_ entity: Entity, _ opacity: Float) {
        let value = min(max(opacity, 0), 1)
        if #available(iOS 18.0, *) {
            entity.components.set(OpacityComponent(opacity: value))
        } else {
            registerOnce()
            var state = entity.components[FadeState.self] ?? FadeState()
            if abs(state.own - value) < 0.002, entity.components[FadeState.self] != nil { return }
            state.own = value
            entity.components.set(state)
            apply(entity, inherited(entity))
        }
    }

    private static var registered = false

    private static func registerOnce() {
        guard !registered else { return }
        registered = true
        FadeState.registerComponent()
        FadeOriginal.registerComponent()
    }

    /// 自分と親たちの透明度を掛け合わせたもの
    private static func inherited(_ entity: Entity) -> Float {
        var value: Float = 1
        var e: Entity? = entity
        while let current = e {
            if let s = current.components[FadeState.self] { value *= s.own }
            e = current.parent
        }
        return value
    }

    private static func apply(_ entity: Entity, _ value: Float) {
        if let model = entity as? ModelEntity, var component = model.model {
            let originals = model.components[FadeOriginal.self]?.materials ?? component.materials
            if model.components[FadeOriginal.self] == nil {
                model.components.set(FadeOriginal(materials: originals))
            }
            component.materials = originals.map { faded($0, value) }
            model.model = component
        }
        for child in entity.children {
            apply(child, value * (child.components[FadeState.self]?.own ?? 1))
        }
    }

    private static func faded(_ material: any Material, _ value: Float) -> any Material {
        if value >= 0.999 { return material }
        if var m = material as? UnlitMaterial {
            var base: Float = 1
            if case .transparent(let o) = m.blending { base = o.scale }
            m.blending = .transparent(opacity: .init(floatLiteral: base * value))
            return m
        }
        if var m = material as? PhysicallyBasedMaterial {
            var base: Float = 1
            if case .transparent(let o) = m.blending { base = o.scale }
            m.blending = .transparent(opacity: .init(floatLiteral: base * value))
            return m
        }
        return material
    }
}

/// iOS 17 用：その entity 自身の透明度
struct FadeState: Component {
    var own: Float = 1
}

/// iOS 17 用：透明度を変える前の質感
struct FadeOriginal: Component {
    var materials: [any Material]
}
