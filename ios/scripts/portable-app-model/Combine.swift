// Test-only Linux compatibility surface. This is NOT Combine/Apple SDK validation.
// Never include this file in an application or widget target.
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
