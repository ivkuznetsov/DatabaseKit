//
//  AtomicProperty.swift
//  DatabaseKit
//
//  Created by Ilya Kuznetsov on 8/20/20.
//  Copyright © 2020 Ilya Kuznetsov. All rights reserved.
//

import Foundation

///Wrapper for properties to make them atomic for read/write operations. This is needed to prevent memory errors during access to the value from different threads at the same time.
@propertyWrapper
public class Atomic<T> {
    private var value: T
    private let queue = DispatchQueue(label: "com.atomic")

    ///Initializer
    public init(wrappedValue value: T) {
        self.value = value
    }

    ///Obtain stored value safely using NSLock underthehood.
    public var wrappedValue: T {
        get { queue.sync { value } }
        set { queue.sync { value = newValue } }
    }
    
    public func mutate(_ mutation: (inout T) -> Void) {
        return queue.sync {
            mutation(&value)
        }
    }
}
