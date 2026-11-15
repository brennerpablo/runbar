import SwiftUI

/// Same as `@State`. In the macOS 27 SDK `@State` became a macro whose plugin only ships with Xcode;
/// this wrapper uses the `State` type directly, so the project builds with just the Command Line Tools.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
