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
    
    public var processUpdateNotification: ((_ classes: Set<String>, _ created: Set<URL>, _ updated: Set<URL>, _ deleted: Set<URL>)->())?
    
    public lazy var storeDescriptions = [StoreDescription.userDataStore()]
    public var customModelBundle: Bundle?

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(contextChanged(notification:)), name: Notification.Name.NSManagedObjectContextDidSave, object: nil)
    }
    
    @objc open var viewContext: NSManagedObjectContext {
        if innerViewContext == nil {
            setupPersistentStore()
        }
        return innerViewContext!
    }
    
    private var writerContext: NSManagedObjectContext {
        if innerWriterContext == nil {
            setupPersistentStore()
        }
        return innerWriterContext!
    }
    
    ///Performs closure with private context on database editing queue. Syncronously if it's performed on background queu and asynchrously in case of main queue.
    @objc open func perform(_ closure: @escaping (NSManagedObjectContext) -> ()) {
        let run = {
            let context = self.createPrivateContext()
            
            context.performAndWait {
                closure(context)
            }
        }
        if Thread.isMainThread {
            onEditQueueSync(run)
        } else {
            onEditQueue(run)
        }
    }
    
    @discardableResult
    func onEditQueueSync<T>(_ closure: ()->T) -> T {
        serialQueue.sync(execute: closure)
    }
    
    func onEditQueue(_ closure: @escaping ()->()) {
        serialQueue.async(execute: closure)
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
        if storeCoordinator == nil {
            setupPersistentStore()
        }
        
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.parent = writerContext
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
            var deletedSet = Set<URL>()
            
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
            if let deleted = notification.userInfo?["deleted"] as? Set<NSManagedObject>, deleted.count > 0 {
                deletedSet = Set(deleted.map {
                    classes.insert(String(describing: type(of: $0)))
                    return $0.objectID.uriRepresentation()
                })
            }
            
            DispatchQueue.main.async {
                self.innerViewContext?.mergeChanges(fromContextDidSave: notification)
                self.processUpdateNotification?(classes, createdSet, updatedSet, deletedSet)
            }
            
            privateContextsForMerge.forEach {
                if let mergeContext = $0.context, context.savingChild != mergeContext {
                    mergeContext.perform {
                        mergeContext.mergeChanges(fromContextDidSave: notification)
                    }
                }
            }
            _privateContextsForMerge.mutate { $0.removeAll { $0.context == nil } }
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
