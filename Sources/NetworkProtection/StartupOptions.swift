//
//  StartupOptions.swift
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
import Common

/// This class handles the proper parsing of the startup options for our tunnel.
///
struct StartupOptions {

    enum StartupMethod: CustomDebugStringConvertible {
        /// Case started up manually from the main app.
        ///
        case manualByMainApp

        /// Started up manually from a Syste provided source: it can be the VPN menu, a CLI command
        /// or the list of VPNs in System Settings.
        ///
        case manualByTheSystem

        /// Started up automatically by on-demand.
        ///
        case automaticOnDemand

        var debugDescription: String {
            switch self {
            case .automaticOnDemand:
                return "automatically by On-Demand"
            case .manualByMainApp:
                return "manually by the main app"
            case .manualByTheSystem:
                return "manually by the system"
            }
        }
    }

    /// Stored options are the options that the our network extension stores / remembers.
    ///
    /// Since these options are stored, the logic can allow for
    ///
    enum StoredOption<T: Equatable>: Equatable {
        case set(_ value: T)
        case reset
        case useExisting

        init(resetIfNil: Bool, getValue: () -> T?) {
            guard let value = getValue() else {
                if resetIfNil {
                    self = .reset
                } else {
                    self = .useExisting
                }

                return
            }

            self = .set(value)
        }

        // MARK: - Equatable

        static func == (lhs: StartupOptions.StoredOption<T>, rhs: StartupOptions.StoredOption<T>) -> Bool {
            switch (lhs, rhs) {
            case (.reset, .reset):
                return true
            case (.set(let lValue), .set(let rValue)):
                return lValue == rValue
            case (.useExisting, .useExisting):
                return true
            default:
                return false
            }
        }
    }

    private let log: OSLog
    let startupMethod: StartupMethod
    let simulateError: Bool
    let simulateCrash: Bool
    let simulateMemoryCrash: Bool
    let keyValidity: StoredOption<TimeInterval>
    let selectedEnvironment: StoredOption<VPNSettings.SelectedEnvironment>
    let selectedServer: StoredOption<VPNSettings.SelectedServer>
    let authToken: StoredOption<String>
    let enableTester: StoredOption<Bool>

    init(options: [String: Any], log: OSLog) {
        self.log = log

        let startupMethod: StartupMethod = {
            if options[NetworkProtectionOptionKey.isOnDemand] as? Bool == true {
                return .automaticOnDemand
            } else if options[NetworkProtectionOptionKey.activationAttemptId] != nil {
                return .manualByMainApp
            } else {
                return .manualByTheSystem
            }
        }()

        self.startupMethod = startupMethod

        simulateError = options[NetworkProtectionOptionKey.tunnelFailureSimulation] as? Bool ?? false
        simulateCrash = options[NetworkProtectionOptionKey.tunnelFatalErrorCrashSimulation] as? Bool ?? false
        simulateMemoryCrash = options[NetworkProtectionOptionKey.tunnelMemoryCrashSimulation] as? Bool ?? false

        let resetStoredOptionsIfNil = startupMethod == .manualByMainApp
        authToken = Self.readAuthToken(from: options, resetIfNil: resetStoredOptionsIfNil)
        enableTester = Self.readEnableTester(from: options, resetIfNil: resetStoredOptionsIfNil)
        keyValidity = Self.readKeyValidity(from: options, resetIfNil: resetStoredOptionsIfNil)
        selectedEnvironment = Self.readSelectedEnvironment(from: options, resetIfNil: resetStoredOptionsIfNil)
        selectedServer = Self.readSelectedServer(from: options, resetIfNil: resetStoredOptionsIfNil)
    }

    // MARK: - Helpers for reading stored options

    private static func readAuthToken(from options: [String: Any], resetIfNil: Bool) -> StoredOption<String> {

        StoredOption(resetIfNil: resetIfNil) {
            guard let authToken = options[NetworkProtectionOptionKey.authToken] as? String,
                  !authToken.isEmpty else {
                return nil
            }

            return authToken
        }
    }

    private static func readKeyValidity(from options: [String: Any], resetIfNil: Bool) -> StoredOption<TimeInterval> {
        StoredOption(resetIfNil: resetIfNil) {
            guard let keyValidityString = options[NetworkProtectionOptionKey.keyValidity] as? String,
                  let keyValidity = TimeInterval(keyValidityString) else {

                return nil
            }

            return keyValidity
        }
    }

    private static func readSelectedEnvironment(from options: [String: Any], resetIfNil: Bool) -> StoredOption<VPNSettings.SelectedEnvironment> {

        StoredOption(resetIfNil: resetIfNil) {
            guard let environment = options[NetworkProtectionOptionKey.selectedEnvironment] as? String else {
                return nil
            }

            return VPNSettings.SelectedEnvironment(rawValue: environment) ?? .default
        }
    }

    private static func readSelectedServer(from options: [String: Any], resetIfNil: Bool) -> StoredOption<VPNSettings.SelectedServer> {

        StoredOption(resetIfNil: resetIfNil) {
            guard let serverName = options[NetworkProtectionOptionKey.selectedServer] as? String else {
                return nil
            }

            return .endpoint(serverName)
        }
    }

    private static func readEnableTester(from options: [String: Any], resetIfNil: Bool) -> StoredOption<Bool> {

        StoredOption(resetIfNil: resetIfNil) {
            guard let value = options[NetworkProtectionOptionKey.connectionTesterEnabled] as? Bool else {
                return nil
            }

            return value
        }
    }
}
