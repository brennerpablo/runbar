import SwiftUI

/// Igual ao `@State`. No SDK do macOS 27, `@State` virou macro e o plugin dela só vem com o Xcode;
/// este wrapper usa o tipo `State` direto, então o projeto compila só com o Command Line Tools.
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
