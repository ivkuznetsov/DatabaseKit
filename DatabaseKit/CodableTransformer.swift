//
//  CodableTransformer.swift
//  DatabaseKit
//
//  Created by Ilya Kuznetsov on 11/6/21.
//  Copyright © 2021 Ilya Kuznetsov. All rights reserved.
//

import Foundation

fileprivate extension Encodable {
    
  func jsonEncode(using encoder: JSONEncoder) throws -> Data {
      return try encoder.encode(self)
  }
}

fileprivate extension Decodable {
    
  static func jsonDecode(using decoder: JSONDecoder, from data: Data) throws -> Self {
      return try decoder.decode(self, from: data)
  }
}
    
class CodableTransformer: ValueTransformer {
    
    override class func transformedValueClass() -> AnyClass { NSData.self }

    override open func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let value = value as? Data else { return nil }
        
        let dict = try! JSONSerialization.jsonObject(with: value, options: []) as! [String: String]
        let className = dict.keys.first!
        let dataString = dict.values.first!
        
        let data = Data(base64Encoded: dataString)!
        
        if let classObject = NSClassFromString(className) as? Decodable.Type {
            return try! classObject.jsonDecode(using: JSONDecoder(), from: data)
        }
        return nil
    }

    override class func allowsReverseTransformation() -> Bool { true }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let value = value as? AnyObject & Encodable else { return nil }
        
        let className = NSStringFromClass(type(of: value))
        let jsonData = try! value.jsonEncode(using: JSONEncoder())
        
        let dict: [String: String] = [className : jsonData.base64EncodedString()]
        
        return try! JSONSerialization.data(withJSONObject: dict, options: [])
    }
}
