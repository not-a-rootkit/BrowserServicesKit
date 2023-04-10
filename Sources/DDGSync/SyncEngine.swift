//
//  Engine.swift
//  DuckDuckGo
//
//  Copyright © 2023 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import Combine

/**
 * Defines sync feature, i.e. type of synced data.
 */
public struct Feature: Hashable {
    var name: String
}

/**
 * Describes a data model that is supported by Sync.
 *
 * Any data model that is passed to Sync Engine is supposed to be encrypted as needed.
 */
public struct Syncable {
    public var payload: [String: Any]

    public init(jsonObject: [String: Any]) {
        payload = jsonObject
    }
}

/**
 * Describes data source for objects to be synced with the server.
 */
public protocol DataProviding {
    /**
     * Feature that is supported by this provider.
     *
     * This is passed to `GET /{types_csv}`.
     */
    var feature: Feature { get }

    /**
     * Time of last successful sync of a given feature.
     *
     * Note that it's a String as this is the server timestamp and should not be treated as date
     * and as such used in comparing timestamps. It's merely an identifier of last sync.
     */
    var lastSyncTimestamp: String? { get }

    /**
     * Client apps should implement this function and return data to be synced for `feature` based on `timestamp`.
     *
     * If `timestamp` is nil, include all objects.
     */
    func changes(since timestamp: String?) async throws -> [Syncable]
}

/**
 * Data returned by sync engine's results publisher.
 *
 * Can be queried by client apps to retrieve changes.
 */
public protocol ResultsProviding {
    var feature: Feature { get }
    var sent: [Syncable] { get }
    var received: [Syncable] { get }
    var lastSyncTimestamp: String? { get }
}

// MARK: - Internal

/**
 * Internal interface for sync schedulers.
 */
protocol SchedulingInternal: Scheduling {
    /// Publishes events to notify Sync Engine that sync operation should be started.
    var startSyncPublisher: AnyPublisher<Void, Never> { get }
}

/**
 * Internal interface for sync engine.
 */
protocol EngineProtocol: ResultsPublishing {
    /// Used for passing data to sync
    var dataProviders: [DataProviding] { get }
    /// Called to start sync
    func startSync()
}

/**
 * Internal interface for sync worker.
 */
protocol WorkerProtocol {
    var dataProviders: [Feature: DataProviding] { get }

    func sync() async throws -> [ResultsProviding]
}

// MARK: - Example Implementation

class SyncScheduler: SchedulingInternal {
    func notifyDataChanged() {
        syncTriggerSubject.send()
    }

    func notifyAppLifecycleEvent() {
        appLifecycleEventSubject.send()
    }

    func requestSyncImmediately() {
        syncTriggerSubject.send()
    }

    let startSyncPublisher: AnyPublisher<Void, Never>

    init() {
        let throttledAppLifecycleEvents = appLifecycleEventSubject
            .throttle(for: .seconds(Const.appLifecycleEventsDebounceInterval), scheduler: DispatchQueue.main, latest: true)

        let throttledSyncTriggerEvents = syncTriggerSubject
            .throttle(for: .seconds(Const.immediateSyncDebounceInterval), scheduler: DispatchQueue.main, latest: true)

        startSyncPublisher = startSyncSubject.eraseToAnyPublisher()

        startSyncCancellable = Publishers.Merge(throttledAppLifecycleEvents, throttledSyncTriggerEvents)
            .sink(receiveValue: { [weak self] _ in
                self?.startSyncSubject.send()
            })
    }

    private let appLifecycleEventSubject: PassthroughSubject<Void, Never> = .init()
    private let syncTriggerSubject: PassthroughSubject<Void, Never> = .init()
    private let startSyncSubject: PassthroughSubject<Void, Never> = .init()
    private var startSyncCancellable: AnyCancellable?

    enum Const {
        static let immediateSyncDebounceInterval = 1
        static let appLifecycleEventsDebounceInterval = 600
    }
}

struct ResultsProvider: ResultsProviding {
    let feature: Feature

    var lastSyncTimestamp: String?

    var sent: [Syncable] = []
    var received: [Syncable] = []
}

class Engine: EngineProtocol {

    let dataProviders: [DataProviding]
    let results: AnyPublisher<[ResultsProviding], Never>

    init(
        dataProviders: [DataProviding],
        api: RemoteAPIRequestCreating,
        endpoints: Endpoints
    ) {
        self.dataProviders = dataProviders
        self.worker = Worker(dataProviders: dataProviders, api: api, endpoints: endpoints)

        results = resultsSubject.eraseToAnyPublisher()
    }

    func startSync() {
        Task {
            let results = try await worker.sync()
            resultsSubject.send(results)
        }
    }

    private let worker: WorkerProtocol
    private let resultsSubject = PassthroughSubject<[ResultsProviding], Never>()
}

actor Worker: WorkerProtocol {

    let dataProviders: [Feature: DataProviding]
    let endpoints: Endpoints
    let api: RemoteAPIRequestCreating

    init(
        dataProviders: [DataProviding],
        api: RemoteAPIRequestCreating,
        endpoints: Endpoints
    ) {
        var providersDictionary = [Feature: DataProviding]()
        for provider in dataProviders {
            providersDictionary[provider.feature] = provider
        }
        self.dataProviders = providersDictionary
        self.endpoints = endpoints
        self.api = api
    }

    func sync() async throws -> [ResultsProviding] {

        // Collect last sync timestamp and changes per feature
        var results = try await withThrowingTaskGroup(of: [Feature: ResultsProvider].self) { group in
            var results: [Feature: ResultsProvider] = [:]

            for dataProvider in self.dataProviders.values {
                let localChanges = try await dataProvider.changes(since: dataProvider.lastSyncTimestamp)
                let resultProvider = ResultsProvider(feature: dataProvider.feature, sent: localChanges)
                results[dataProvider.feature] = resultProvider
            }
            return results
        }

        let hasLocalChanges = results.values.contains(where: { !$0.sent.isEmpty })

        let result: HTTPResult = hasLocalChanges ? try await executePatchRequest(with: results) : try await executeGetRequest()

        guard let data = result.data else {
            throw SyncError.noResponseBody
        }

        guard let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw SyncError.unexpectedResponseBody
        }

        for feature in results.keys {
            guard let featurePayload = jsonObject[feature.name] as? [String: Any] else {
                throw SyncError.unexpectedResponseBody
            }
            results[feature]?.lastSyncTimestamp = featurePayload["last_modified"] as? String
            results[feature]?.received = featurePayload["entries"] as! [Syncable]
        }

        return Array(results.values)
    }

    private func executeGetRequest() async throws -> HTTPResult {
        let request = api.createRequest(url: endpoints.syncGet, method: .GET, headers: [:], parameters: [:], body: nil, contentType: nil)
        return try await request.execute()
    }

    private func executePatchRequest(with results: [Feature: ResultsProviding]) async throws -> HTTPResult {
        var json = [String: Any]()
        for (feature, result) in results {
            let modelPayload: [String: Any?] = [
                "updates": result.sent.map(\.payload),
                "modified_since": dataProviders[feature]?.lastSyncTimestamp
            ]
            json[feature.name] = modelPayload
        }

        let body = try JSONSerialization.data(withJSONObject: json, options: [])
        let request = api.createRequest(url: endpoints.syncPatch, method: .PATCH, headers: [:], parameters: [:], body: body, contentType: "application/json")
        return try await request.execute()
    }
}
