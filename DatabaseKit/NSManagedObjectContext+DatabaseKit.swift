//
//  NSManagedObjectContext+DatabaseKit.swift
//  DatabaseKit
//
//  Created by Ilya Kuznetsov on 11/22/17.
//  Copyright © 2017 Ilya Kuznetsov. All rights reserved.
//

import Foundation
import CoreData
import os.log

extension NSManagedObjectContext {
    
    private func logError(_ error: String) {
        if #available(iOS 10.0, *) {
            os_log("%@", error)
        } else {
            print(error)
        }
    }
    
    public func create<T: NSManagedObject>(type: T.Type) -> T {
        return NSEntityDescription.insertNewObject(forEntityName: NSStringFromClass(type), into: self) as! T
    }
    
    // todo this later
    /*public func create<T: NSManagedObject>(type: T.Type, configuration: String) -> T {
        //let object = self.create(type: type)
        //let store = DatabaseKit.persistentStoreFor(configuration: configuration)
        //self.assign(object, to: store!)
        return object
    }*/
    
    private func entityDescription<T: NSManagedObject>(type: T.Type) -> NSEntityDescription {
        return NSEntityDescription.entity(forEntityName: NSStringFromClass(type), in: self)!
    }
    
    public func execute<T: NSManagedObject>(request: NSFetchRequest<T>, type: T.Type) throws -> [T] {
        request.entity = self.entityDescription(type: type)
        return try self.fetch(request)
    }
    
    public func allObjects<T: NSManagedObject>(_ type: T.Type) -> [T] {
        let request = NSFetchRequest<T>()
        
        do {
            return try execute(request: request, type:type)
        } catch {
            logError(error.localizedDescription)
        }
        return []
    }
    
    public func allObjectsSorted<T: NSManagedObject>(_ type: T.Type) -> [T] {
        return allObjectsSortedBy(key: \T.objectID.description, type: type)
    }
    
    public func allObjectsSortedBy<T: NSManagedObject, U>(key: KeyPath<T, U>, type: T.Type) -> [T] where U: Comparable {
        return allObjectsSortedBy(key: key, ascending: true, type: type)
    }
    
    public func allObjectsSortedBy<T: NSManagedObject, U>(key: ReferenceWritableKeyPath<T, U?>, type: T.Type) -> [T] where U: Comparable {
        return allObjectsSortedBy(key: key, ascending: true, type: type)
    }
    
    public func allObjectsSortedBy<T: NSManagedObject, U>(key: ReferenceWritableKeyPath<T, U?>, ascending: Bool, type: T.Type) -> [T] where U: Comparable {
        let request = NSFetchRequest<T>()
        request.sortDescriptors = [NSSortDescriptor(keyPath: key, ascending: ascending)]
        
        do {
            return try execute(request: request, type: type)
        } catch {
            logError(error.localizedDescription)
        }
        return []
    }
    
    public func allObjectsSortedBy<T: NSManagedObject, U>(key: KeyPath<T, U>, ascending: Bool, type: T.Type) -> [T] where U: Comparable {
        let request = NSFetchRequest<T>()
        request.sortDescriptors = [NSSortDescriptor(keyPath: key, ascending: ascending)]
        
        do {
            return try execute(request: request, type: type)
        } catch {
            logError(error.localizedDescription)
        }
        return []
    }
    
    public func find<T: NSManagedObject, U: CVarArg>(type: T.Type, _ keyPath: KeyPath<T, U>, _ value: U) -> [T] {
        let predicate = NSPredicate(format: (value as? String == nil) ? "\(keyPath._kvcKeyPathString!) == \(value)" : "\(keyPath._kvcKeyPathString!) == \"\(value)\"")
        return find(type: type, predicate: predicate)
    }
    
    public func find<T: NSManagedObject, U: CVarArg>(type: T.Type, _ keyPath: ReferenceWritableKeyPath<T, U?>, _ value: U) -> [T] {
        let predicate = NSPredicate(format: (value as? String == nil) ? "\(keyPath._kvcKeyPathString!) == \(value)" : "\(keyPath._kvcKeyPathString!) == \"\(value)\"")
        return find(type: type, predicate: predicate)
    }
    
    public func find<T: NSManagedObject>(type: T.Type, _ format: String, _ args: CVarArg...) -> [T] {
        let predicate = NSPredicate(format: format, arguments: getVaList(args))
        return find(type: type, predicate: predicate)
    }
    
    public func find<T: NSManagedObject>(type: T.Type, predicate: NSPredicate) -> [T] {
        let request = NSFetchRequest<T>()
        request.predicate = predicate
        
        do {
            return try execute(request: request, type: type)
        } catch {
            logError(error.localizedDescription)
        }
        return []
    }
    
    public func findFirst<T: NSManagedObject, U: CVarArg>(type: T.Type, _ keyPath: KeyPath<T, U>, _ value: U) -> T? {
        let predicate = NSPredicate(format: (value as? String == nil) ? "\(keyPath._kvcKeyPathString!) == \(value)" : "\(keyPath._kvcKeyPathString!) == \"\(value)\"")
        return findFirst(type: type, predicate: predicate)
    }
    
    public func findFirst<T: NSManagedObject, U: CVarArg>(type: T.Type, _ keyPath: ReferenceWritableKeyPath<T, U?>, _ value: U) -> T? {
        let predicate = NSPredicate(format: (value as? String == nil) ? "\(keyPath._kvcKeyPathString!) == \(value)" : "\(keyPath._kvcKeyPathString!) == \"\(value)\"")
        return findFirst(type: type, predicate: predicate)
    }
    
    public func findFirst<T: NSManagedObject>(type: T.Type, _ format: String, _ args: CVarArg...) -> T? {
        let predicate = NSPredicate(format: format, arguments: getVaList(args))
        return findFirst(type: type, predicate: predicate)
    }
    
    public func findFirst<T: NSManagedObject>(type: T.Type, predicate: NSPredicate) -> T? {
        let request = NSFetchRequest<T>()
        request.fetchLimit = 1
        request.predicate = predicate
        
        do {
            return try execute(request: request, type: type).first
        } catch {
            logError(error.localizedDescription)
        }
        return nil
    }
    
    public func objectsWith<T: Sequence>(ids: T) -> [NSManagedObject] where T.Element: NSManagedObjectID {
        return ids.compactMap { return find(type: NSManagedObject.self, objectId: $0) }
    }
    
    public func objectsWith<T: Sequence, U: NSManagedObject>(ids: T, type: U.Type) -> [U] where T.Element: NSManagedObjectID {
        return ids.compactMap { return find(type: type, objectId: $0) }
    }
    
    public func find<T: NSManagedObject>(type: T.Type, objectId: NSManagedObjectID) -> T? {
        do {
            return try self.existingObject(with: objectId) as? T
        } catch {
            logError(error.localizedDescription)
        }
        return nil
    }
    
    @objc public func saveAll() {
        precondition(concurrencyType != .mainQueueConcurrencyType, "View context cannot be saved")
        
        if hasChanges {
            performAndWait {
                do {
                    try save()
                } catch {
                    logError(error.localizedDescription)
                    logError(String(describing: (error as NSError).userInfo))
                    return
                }
                if parent != nil && parent!.hasChanges == true {
                    parent!.performAndWait {
                        do {
                            try parent!.save()
                        } catch {
                            logError(error.localizedDescription)
                            logError(String(describing: (error as NSError).userInfo))
                            return
                        }
                    }
                }
            }
        }
    }
}

//ObjC support
@available(swift, obsoleted: 1.0)
public extension NSManagedObjectContext {
    
    @objc func create(_ type: AnyClass) -> Any {
        return create(type: type as! NSManagedObject.Type)
    }
    
    @objc func find(objectId: NSManagedObjectID?) -> Any? {
        if let objectId = objectId {
            return try? self.existingObject(with: objectId)
        }
        return nil
    }
    
    @objc func findFirst(_ type: AnyClass, key: String, value: Any) -> Any? {
        let predicate = NSPredicate(format: "\(key) == %@", argumentArray: [value])
        return findFirst(type: type as! NSManagedObject.Type, predicate: predicate)
    }
    
    @objc func find(_ type: AnyClass, key: String, value: Any) -> [Any] {
        let predicate = NSPredicate(format: "\(key) == %@", argumentArray: [value])
        return find(type: type as! NSManagedObject.Type, predicate: predicate)
    }
    
    @objc func findFirst(_ type: AnyClass, predicate: NSPredicate) -> Any? {
        return findFirst(type: type as! NSManagedObject.Type, predicate: predicate)
    }
    
    @objc func find(_ type: AnyClass, predicate: NSPredicate) -> [Any] {
        return find(type: type as! NSManagedObject.Type, predicate: predicate)
    }
    
    @objc func objects(ids: [NSManagedObjectID]) -> [NSManagedObject] {
        return objectsWith(ids: ids)
    }
    
    @objc func allObjectsFor(_ type: AnyClass) -> [Any] {
        return allObjects(type as! NSManagedObject.Type)
    }
}

