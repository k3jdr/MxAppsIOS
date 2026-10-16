//
//  Formatting.swift
//  MxDataHUB
//
//  Number formatting and the label / value row shared by the screens.
//

import SwiftUI

/// "12.3456%" for a fraction.
func percentText(_ value: Double?, digits: Int = 4) -> String {
    guard let value else { return "" }
    return (value * 100).formatted(.number.precision(.fractionLength(digits))) + "%"
}

func numberText(_ value: Double?, digits: Int = 2) -> String {
    guard let value else { return "" }
    return value.formatted(.number.precision(.fractionLength(digits)))
}

/// A label / value grid row used by the detail panels.
struct FactRow: View {
    let name: String
    let value: String
    var body: some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).gridColumnAlignment(.leading)
        }
    }
}
