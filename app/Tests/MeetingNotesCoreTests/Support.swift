import Testing

/// `#expect` for expressions with mutating calls, which the macro cannot decompose.
func check(_ condition: Bool, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(condition, comment, sourceLocation: sourceLocation)
}
