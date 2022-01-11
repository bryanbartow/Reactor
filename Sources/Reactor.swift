import Foundation


// MARK: - State

public protocol Store {
    mutating func react(to event: Event)
}


// MARK: - Events

public protocol Event {}


// MARK: - Commands

public protocol Command {
    associatedtype StoreType: Store
    func execute(store: StoreType, core: Core<StoreType>)
}


// MARK: - Middlewares

public protocol AnyMiddleware {
    func _process(event: Event, store: Any)
}

public protocol Middleware: AnyMiddleware {
    associatedtype StoreType
    func process(event: Event, store: StoreType)
}

extension Middleware {
    public func _process(event: Event, store: Any) {
        if let store = store as? StoreType {
            process(event: event, store: store)
        }
    }
}

public struct Middlewares<StoreType: Store> {
    private(set) var middleware: AnyMiddleware
}


// MARK: - Subscribers

public protocol AnySubscriber: class {
    func _update(with store: Any)
}

public protocol Subscriber: AnySubscriber {
    associatedtype StoreType
    func update(with store: StoreType)
}

extension Subscriber {
    public func _update(with store: Any) {
        if let store = store as? StoreType {
            update(with: store)
        }
    }
}

public struct Subscription<StoreType: Store> {
    private(set) weak var subscriber: AnySubscriber? = nil
    let selector: ((StoreType) -> Any)?
    let notifyQueue: DispatchQueue

    fileprivate func notify(with store: StoreType) {
        notifyQueue.async {
            if let selector = self.selector {
                self.subscriber?._update(with: selector(store))
            } else {
                self.subscriber?._update(with: store)
            }
        }
    }
}



// MARK: - Core

public class Core<StoreType: Store> {
    
    private let jobQueue: DispatchQueue
    private var subscriptions = [Subscription<StoreType>]()

    private let middlewares: [Middlewares<StoreType>]

    public private (set) var store: StoreType {
        didSet {
            for subscription in self.subscriptions {
                subscription.notify(with: store)
            }
        }
    }
    
    public init(store: StoreType, middlewares: [AnyMiddleware] = []) {
        self.store = store
        self.middlewares = middlewares.map(Middlewares.init)
        let qos: DispatchQoS
        if #available(macOS 10.10, *) {
            qos = .userInitiated
        } else {
            qos = .unspecified
        }
        self.jobQueue = DispatchQueue(label: "reactor.core.queue", qos: qos, attributes: [])
    }

    
    // MARK: - Subscriptions
    
    public func add(subscriber: AnySubscriber, notifyOnQueue queue: DispatchQueue? = DispatchQueue.main, selector: ((StoreType) -> Any)? = nil) {
        jobQueue.async {
            guard !self.subscriptions.contains(where: {$0.subscriber === subscriber}) else { return }
            self.subscriptions = self.subscriptions.filter { $0.subscriber != nil }
            let subscription = Subscription(subscriber: subscriber, selector: selector, notifyQueue: queue ?? self.jobQueue)
            self.subscriptions.append(subscription)
            subscription.notify(with: self.store)
        }
    }
    
    public func remove(subscriber: AnySubscriber) {
        // sync to limit `nil` subscribers by ensuring they're removed before they `deinit`.
        jobQueue.sync {
            subscriptions = subscriptions.filter { $0.subscriber !== subscriber && $0.subscriber != nil }
        }
    }
    
    // MARK: - Events
    
    public func fire(event: Event) {
        jobQueue.async {
            self.store.react(to: event)
            self.middlewares.forEach { $0.middleware._process(event: event, store: self.store) }
        }
    }
    
    public func fire<C: Command>(command: C) where C.StoreType == StoreType {
        jobQueue.async {
            command.execute(store: self.store, core: self)
        }
    }
}
