//
//  DatabaseKit.swift
//  DatabaseKit
//
//  Created by Ilya Kuznetsov on 11/20/17.
//  Copyright © 2017 Ilya Kuznetsov. All rights reserved.
//

import Foundation
import CoreData
import os.log

//  Do any changes only by 'perform()' function, they will be performed on background queue, do not forget to save by 'ctx.saveAll()'
//  Use 'viewContext' for getting objects to the main thread and presenting in UI
//  You can't use 'viewContext' to change objects, it's read only.
//
//  sample Implementation:
//
//  let database = Database()
//
//  database.perform { (ctx) in
//
//      let object = ctx.create(type: SampleObject.self)
//
//      ctx.saveAll()
//  }
//
//  let objects = database.viewContext().allObjects(SampleObject.self)
//

@objcMembers
@objc(DKDatabaseKit)
open class Database: NSObject {
    
    fileprivate class WeakContext {
        weak var context: NSManagedObjectContext?
        
        init(_ context: NSManagedObjectContext) {
            self.context = context
        }
    }
    
    @Atomic fileprivate var storeCoordinator: NSPersistentStoreCoordinator!
    fileprivate let serialQueue = DispatchQueue(label: "database.serialqueue")
    @Atomic fileprivate var innerViewContext: NSManagedObjectContext?
    @Atomic fileprivate var innerWriterContext: NSManagedObjectContext?
    @Atomic fileprivate var privateContextsForMerge: [WeakContext] = []
    
    public var processUpdateNotification: ((/*classes*/ Set<String>, /*created URIs*/ Set<URL>, /*updated URIs*/ Set<URL>)->())?
    
    public lazy var storeDescriptions = [StoreDescription.userDataStore()]
    public var customModelBundle: Bundle?

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(contextChanged(notification:)), name: Notification.Name.NSManagedObjectContextDidSave, object: nil)
    }
    
    @objc open func viewContext() -> NSManagedObjectContext {
        if innerViewContext == nil {
            setupPersistentStore()
        }
        return innerViewContext!
    }
    
    private func writerContext() -> NSManagedObjectContext {
        if innerWriterContext == nil {
            setupPersistentStore()
        }
        return innerWriterContext!
    }
    
    @objc open func perform(_ closure: @escaping (NSManagedObjectContext) -> ()) {
        if storeCoordinator == nil {
            setupPersistentStore()
        }
        
        let run = {
            let context = self.createPrivateContext()
            
            context.performAndWait {
                closure(context)
            }
        }
        performOnChangeQueue(run)
    }
    
    public func performOnChangeQueue(_ closure: @escaping ()->()) {
        if Thread.isMainThread {
            serialQueue.async(execute: closure)
        } else {
            serialQueue.sync(execute: closure)
        }
    }
    
    public func onPrivate(_ closure: (NSManagedObjectContext)->()) {
        let ctx = createPrivateContext()
        ctx.performAndWait {
            closure(ctx)
        }
    }
    
    @discardableResult
    func onPrivate<T>(_ closure: (NSManagedObjectContext)->T?) -> T? {
        let ctx = createPrivateContext()
        var result: T?
        ctx.performAndWait {
            result = closure(ctx)
        }
        return result
    }
    
    public func onPrivateAsync(_ closure: @escaping (NSManagedObjectContext)->()) {
        let ctx = createPrivateContext()
        ctx.perform {
            closure(ctx)
        }
    }
    
    public func onPrivateWith<U: NSManagedObject>(_ object: U, closure: (U, NSManagedObjectContext)->()) {
        let ctx = createPrivateContext()
        let objectId = object.objectID
        ctx.performAndWait {
            if let object = ctx.find(type: U.self, objectId: objectId) {
                closure(object, ctx)
            }
        }
    }
    
    @discardableResult
    public func onPrivateWith<T, U: NSManagedObject>(_ object: U, closure: (U, NSManagedObjectContext)->T?) -> T? {
        let ctx = createPrivateContext()
        var result: T?
        let objectId = object.objectID
        ctx.performAndWait {
            if let object = ctx.find(type: U.self, objectId: objectId) {
                result = closure(object, ctx)
            }
        }
        return result
    }
    
    public func performWith<T: NSManagedObject>(_ object: T, closure: @escaping (T, NSManagedObjectContext)->()) {
        let objectId = object.objectID
        perform { ctx in
            if let object = ctx.find(type: T.self, objectId: objectId) {
                closure(object, ctx)
                ctx.saveAll()
            }
        }
    }
    
    open func reset() {
        setupPersistentStore()
    }
    
    open func idFor(uriRepresentation: URL) -> NSManagedObjectID? {
        if storeCoordinator == nil {
            setupPersistentStore()
        }
        return self.storeCoordinator.managedObjectID(forURIRepresentation: uriRepresentation)
    }
    
    open func persistentStoreFor(configuration: String) -> NSPersistentStore? {
        return persistentStoreAt(url: storeDescriptionFor(configuration: configuration).url)
    }
    
    open func createPrivateContext(mergeChanges: Bool) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.parent = writerContext()
        if mergeChanges {
            _privateContextsForMerge.mutate { $0.append(WeakContext(context)) }
        }
        return context
    }
    
    open func createPrivateContext() -> NSManagedObjectContext {
        return createPrivateContext(mergeChanges: false)
    }
    
    func log(message: String) {
        if #available(iOS 10.0, *) {
            os_log("%@", message)
        } else {
            print(message)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

fileprivate extension Database {
    
    @objc func contextChanged(notification: Notification) {
        if let context = notification.object as? NSManagedObjectContext, context == innerWriterContext {
            
            var classes = Set<String>()
            var createdSet = Set<URL>()
            var updatedSet = Set<URL>()
            
            if let inserted = notification.userInfo?["inserted"] as? Set<NSManagedObject>, inserted.count > 0 {
                createdSet = Set(inserted.map {
                    classes.insert(String(describing: type(of: $0)))
                    return $0.objectID.uriRepresentation()
                })
            }
            if let updated = notification.userInfo?["updated"] as? Set<NSManagedObject>, updated.count > 0 {
                updatedSet = Set(updated.map {
                    classes.insert(String(describing: type(of: $0)))
                    return $0.objectID.uriRepresentation()
                })
            }
            
            performOnMain {
                self.innerViewContext?.mergeChanges(fromContextDidSave: notification)
                self.processUpdateNotification?(classes, createdSet, updatedSet)
            }
            
            _privateContextsForMerge.mutate {
                $0.removeAll {
                    if let mergeContext = $0.context, context.savingChild != mergeContext {
                        mergeContext.performAndWait {
                            mergeContext.mergeChanges(fromContextDidSave: notification)
                        }
                        return false
                    }
                    return true
                }
            }
        }
    }
    
    private func persistentStoreAt(url: URL) -> NSPersistentStore? {
        return storeCoordinator.persistentStore(for: url)
    }
    
    private func storeDescriptionFor(configuration: String) -> StoreDescription {
        return storeDescriptions.first { $0.configuration == configuration }!
    }
    
    func setupPersistentStore() {
        let setup = {
            if self.storeCoordinator != nil { return }
            
            var bundles = [Bundle.main]
            
            if let bundle = self.customModelBundle {
                bundles.append(bundle)
            }
            
            let objectModel = NSManagedObjectModel.mergedModel(from: bundles)!
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: objectModel)
            
            self.addStoresTo(coordinator: coordinator)
            
            let writerContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            writerContext.persistentStoreCoordinator = coordinator
            writerContext.mergePolicy = NSOverwriteMergePolicy
            
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.mergePolicy = NSRollbackMergePolicy
            
            self.storeCoordinator = coordinator
            self.innerWriterContext = writerContext
            self.innerViewContext = context
        }
        
        performOnMain { setup() }
    }
    
    private func performOnMain(_ block: ()->()) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }
    
    private func addStoresTo(coordinator: NSPersistentStoreCoordinator) {
        for identifier in coordinator.managedObjectModel.configurations {
            addStoreWith(configuration: identifier, toCoordinator: coordinator)
        }
    }
    
    private func addStoreWith(configuration: String, toCoordinator coordinator: NSPersistentStoreCoordinator) {
        let description = storeDescriptionFor(configuration: configuration)
        
        var options: [String : Any] = [NSMigratePersistentStoresAutomaticallyOption : true, NSInferMappingModelAutomaticallyOption : true]
        
        if description.readOnly {
            options[NSReadOnlyPersistentStoreOption] = true
        }
        
        description.options?.forEach { options[$0.key] = $0.value }
        
        do {
            try coordinator.addPersistentStore(ofType: description.storeType, configurationName: configuration, at: description.url, options: options)
            
            log(message: "Store has been added: \(description.url.path)")
        } catch {
            log(message: "Error while creating persistent store: \(error.localizedDescription) for configuration \(configuration)")
            if description.deleteOnError {
                description.removeStoreFiles()
                addStoreWith(configuration: configuration, toCoordinator: coordinator)
            }
        }
    }
}
