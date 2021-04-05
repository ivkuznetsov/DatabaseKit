//
//  Fetchable.swift
//

import Foundation
import CoreData

public protocol Fetchable {
    
    var uid: String? { get set }
    func update(_ dict: [AnyHashable : Any])
}

public protocol CustomId {
    
    static func id(from dict: [AnyHashable : Any]) -> String
}

public protocol CustomDBSearch {
    
    static func findObject(uid: String, ctx: NSManagedObjectContext) -> NSManagedObject?
}

public extension Fetchable {
    
    func parse<U>(_ dict: [AnyHashable : Any], _ keys: [(dbKey: ReferenceWritableKeyPath<Self, U?>, serviceKey: String)], dateConverted: ((String)->(Date?))? = nil) {
        for key in keys {
            if let value = dict[key.serviceKey] {
                if let value = value as? U {
                    self[keyPath: key.dbKey] = value
                } else if let value = value as? String, let dbKey = key.dbKey as? ReferenceWritableKeyPath<Self, Date?> {
                    self[keyPath: dbKey] = dateConverted?(value)
                } else {
                    self[keyPath: key.dbKey] = nil
                }
            }
        }
    }
    
    func parse<U>(_ dict: [AnyHashable : Any], _ keys: [(dbKey: ReferenceWritableKeyPath<Self, U>, serviceKey: String)]) {
        for key in keys {
            if let value = dict[key.serviceKey] {
                if let value = value as? U {
                    self[keyPath: key.dbKey] = value
                } else if let value = value as? String {
                    if let dbKey = key.dbKey as? ReferenceWritableKeyPath<Self, Float> {
                        self[keyPath: dbKey] = Float(value) ?? 0
                    } else if let dbKey = key.dbKey as? ReferenceWritableKeyPath<Self, Double> {
                        self[keyPath: dbKey] = Double(value) ?? 0
                    } else if let dbKey = key.dbKey as? ReferenceWritableKeyPath<Self, Bool> {
                        self[keyPath: dbKey] = value == "1" ? true : (value == "true" ? true : false)
                    }
                } else if let dbKey = key.dbKey as? ReferenceWritableKeyPath<Self, Float>, let value = value as? Double {
                    self[keyPath: dbKey] = Float(value)
                }
            }
        }
    }
    
    static func id(serviceObject: [AnyHashable : Any]) -> String {
        if let item = self as? CustomId.Type {
            return item.id(from: serviceObject)
        }
        
        var uid: String! = serviceObject["uid"] as? String ?? serviceObject["id"] as? String
        
        if uid == nil, let id = serviceObject["id"] as? Int64 {
            uid = "\(id)"
        }
        if uid == nil {
            uid = "0"
        }
        if uid == "0" {
            print("ID is not found, throwed by class: \(String(describing: self))")
        }
        return uid
    }
}

public extension Fetchable where Self: NSManagedObject {
    
    func parse<T: Fetchable & NSManagedObject>(_ dict: [AnyHashable : Any], _ dbKey: ReferenceWritableKeyPath<Self, T?>, _ serviceKey: String) {
        if let value = dict[serviceKey] {
            self[keyPath: dbKey] = self.managedObjectContext?.findAndUpdate(T.self, serviceObject: value as? [String : Any])
        }
    }
    
    func parse<T: Fetchable & NSManagedObject>(_ dict: [AnyHashable : Any], _ dbKey: ReferenceWritableKeyPath<Self, Set<T>?>, _ serviceKey: String) {
        if let value = dict[serviceKey] {
            var array: [[String : Any]] = []
            
            if let value = value as? [[String : Any]] {
                array = value
            } else if let value = value as? [Int64] {
                array = value.map { return ["id" : $0] }
            }
            self[keyPath: dbKey] = Set(self.managedObjectContext?.parse(T.self, array: array, additional: nil) ?? [])
        }
    }
}

public protocol FetchableValidation {
    
    static func isValid(dict: [String : Any]) -> Bool
}

public extension NSManagedObjectContext {
    
    func parse<T: Fetchable & NSManagedObject>(_ type: T.Type, array: [[String:Any]]?, additional: ((T, [String:Any])->())?) -> [T] {
        guard let array = array else {
            return []
        }
        var result: [T] = []
        
        for serviceObject in array {
            
            if let type = type as? FetchableValidation.Type, type.isValid(dict: serviceObject) == false {
                continue
            }
            let uid = type.id(serviceObject: serviceObject)
            
            var object: T?
            if object == nil {
                if let type = type as? CustomDBSearch.Type {
                    object = type.findObject(uid: uid, ctx: self) as? T
                } else {
                    object = findFirst(type: type, "uid == %@", uid)
                }
            }
            
            if uid == "0" {
                continue
            }
            if object == nil {
                object = create(type: type)
            }
            object!.uid = uid
            object!.update(serviceObject)
            additional?(object!, serviceObject)
            
            result.append(object!)
        }
        return result
    }
    
    func findOrCreatePlaceholder<T: Fetchable & NSManagedObject>(_ type: T.Type, uid: Any?) -> T? {
        if let uid = uid as? Int64 {
            return findOrCreatePlaceholder(type, uid: uid)
        } else if let uid = uid as? String {
            return findOrCreatePlaceholder(type, uid: String(uid))
        }
        return nil
    }
    
    func findOrCreatePlaceholder<T: Fetchable & NSManagedObject>(_ type: T.Type, uid: String?) -> T? {
        guard let uid = uid else {
            return nil
        }
        var object = findFirst(type: type, "uid == %@", uid)
        
        if object == nil {
            object = create(type: type)
        }
        object!.uid = uid
        return object!
    }
    
    func findAndUpdate<T: Fetchable & NSManagedObject>(_ type: T.Type, serviceObject: [String:Any]?) -> T? {
        guard let serviceObject = serviceObject else {
            return nil
        }
        let uid = type.id(serviceObject: serviceObject)
        let object = findOrCreatePlaceholder(type, uid: uid)
        object?.update(serviceObject)
        return object
    }
    
    static func parseObject<T: Fetchable & NSManagedObject>(_ type: T.Type, serviceObject: [String:Any], database: Database) -> NSManagedObjectID {
        var result: NSManagedObjectID!
        database.perform { (ctx) in
            let object = ctx.findAndUpdate(type, serviceObject: serviceObject)
            ctx.saveAll()
            result = object?.permanentObjectID()
        }
        return result!
    }
    
    static func parseObjects<T: Fetchable & NSManagedObject>(sender: AnyObject?, type: T.Type, serviceObjects: [[String:Any]], additional: ((T, [String:Any])->())? = nil, database: Database) -> [NSManagedObjectID] {
        var result: [NSManagedObjectID] = []
        database.perform { (ctx) in
            result = NSManagedObject.idsWith(objects: ctx.parse(type, array: serviceObjects, additional: additional))
            ctx.saveAll()
        }
        return result
    }
}
