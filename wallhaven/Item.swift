//
//  Item.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
