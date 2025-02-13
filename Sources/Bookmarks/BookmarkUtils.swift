//
//  BookmarkUtils.swift
//
//  Copyright © 2021 DuckDuckGo. All rights reserved.
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
import CoreData

public struct BookmarkUtils {

    public static func fetchRootFolder(_ context: NSManagedObjectContext) -> BookmarkEntity? {
        let request = BookmarkEntity.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(BookmarkEntity.uuid), BookmarkEntity.Constants.rootFolderID)
        request.returnsObjectsAsFaults = false
        request.fetchLimit = 1

        return try? context.fetch(request).first
    }

    public static func fetchFavoritesFolders(for displayMode: FavoritesDisplayMode, in context: NSManagedObjectContext) -> [BookmarkEntity] {
        fetchFavoritesFolders(withUUIDs: displayMode.folderUUIDs, in: context)
    }

    public static func fetchFavoritesFolder(withUUID uuid: String, in context: NSManagedObjectContext) -> BookmarkEntity? {
        assert(BookmarkEntity.isValidFavoritesFolderID(uuid))

        let request = BookmarkEntity.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(BookmarkEntity.uuid), uuid)
        request.returnsObjectsAsFaults = false
        request.fetchLimit = 1

        return try? context.fetch(request).first
    }

    public static func fetchFavoritesFolders(withUUIDs uuids: Set<String>, in context: NSManagedObjectContext) -> [BookmarkEntity] {
        assert(uuids.allSatisfy { BookmarkEntity.isValidFavoritesFolderID($0) })

        let request = BookmarkEntity.fetchRequest()
        request.predicate = NSPredicate(format: "%K in %@", #keyPath(BookmarkEntity.uuid), uuids)
        request.returnsObjectsAsFaults = false
        request.fetchLimit = uuids.count

        return (try? context.fetch(request)) ?? []
    }

    public static func fetchOrphanedEntities(_ context: NSManagedObjectContext) -> [BookmarkEntity] {
        let request = BookmarkEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "NOT %K IN %@ AND %K == NO AND %K == nil",
            #keyPath(BookmarkEntity.uuid),
            BookmarkEntity.Constants.favoriteFoldersIDs.union([BookmarkEntity.Constants.rootFolderID]),
            #keyPath(BookmarkEntity.isPendingDeletion),
            #keyPath(BookmarkEntity.parent)
        )
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(BookmarkEntity.uuid), ascending: true)]
        request.returnsObjectsAsFaults = false

        return (try? context.fetch(request)) ?? []
    }

    public static func prepareFoldersStructure(in context: NSManagedObjectContext) {

        if fetchRootFolder(context) == nil {
            insertRootFolder(uuid: BookmarkEntity.Constants.rootFolderID, into: context)
        }

        for uuid in BookmarkEntity.Constants.favoriteFoldersIDs where fetchFavoritesFolder(withUUID: uuid, in: context) == nil {
            insertRootFolder(uuid: uuid, into: context)
        }
    }

    public static func copyFavorites(
        from sourceFolderID: FavoritesFolderID,
        to targetFolderID: FavoritesFolderID,
        clearingNonNativeFavoritesFolder nonNativeFolderID: FavoritesFolderID,
        in context: NSManagedObjectContext
    ) {
        assert(nonNativeFolderID != .unified, "You must specify either desktop or mobile folder")
        assert(Set([sourceFolderID, targetFolderID, nonNativeFolderID]).count == 3, "You must pass 3 different folder IDs to this function")
        assert([sourceFolderID, targetFolderID].contains(FavoritesFolderID.unified), "You must copy to or from a unified folder")

        let allFavoritesFolders = BookmarkUtils.fetchFavoritesFolders(withUUIDs: Set(FavoritesFolderID.allCases.map(\.rawValue)), in: context)
        assert(allFavoritesFolders.count == FavoritesFolderID.allCases.count, "Favorites folders missing")

        guard let sourceFavoritesFolder = allFavoritesFolders.first(where: { $0.uuid == sourceFolderID.rawValue }),
              let targetFavoritesFolder = allFavoritesFolders.first(where: { $0.uuid == targetFolderID.rawValue }),
              let nonNativeFormFactorFavoritesFolder = allFavoritesFolders.first(where: { $0.uuid == nonNativeFolderID.rawValue })
        else {
            return
        }

        nonNativeFormFactorFavoritesFolder.favoritesArray.forEach { bookmark in
            bookmark.removeFromFavorites(favoritesRoot: nonNativeFormFactorFavoritesFolder)
        }

        targetFavoritesFolder.favoritesArray.forEach { bookmark in
            bookmark.removeFromFavorites(favoritesRoot: targetFavoritesFolder)
        }

        sourceFavoritesFolder.favoritesArray.forEach { bookmark in
            bookmark.addToFavorites(favoritesRoot: targetFavoritesFolder)
        }
    }

    public static func fetchAllBookmarksUUIDs(in context: NSManagedObjectContext) -> [String] {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "BookmarkEntity")
        request.predicate = NSPredicate(format: "%K == NO AND %K == NO",
                                        #keyPath(BookmarkEntity.isFolder),
                                        #keyPath(BookmarkEntity.isPendingDeletion))
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = [#keyPath(BookmarkEntity.uuid)]

        let result = (try? context.fetch(request) as? [Dictionary<String, Any>]) ?? []
        return result.compactMap { $0[#keyPath(BookmarkEntity.uuid)] as? String }
    }

    public static func fetchBookmark(for url: URL,
                                     predicate: NSPredicate = NSPredicate(value: true),
                                     context: NSManagedObjectContext) -> BookmarkEntity? {
        let request = BookmarkEntity.fetchRequest()
        let urlPredicate = NSPredicate(format: "%K == %@ AND %K == NO",
                                       #keyPath(BookmarkEntity.url),
                                       url.absoluteString,
                                       #keyPath(BookmarkEntity.isPendingDeletion))
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [urlPredicate, predicate])
        request.returnsObjectsAsFaults = false
        request.fetchLimit = 1

        return try? context.fetch(request).first
    }

    public static func fetchBookmarksPendingDeletion(_ context: NSManagedObjectContext) -> [BookmarkEntity] {
        let request = BookmarkEntity.fetchRequest()
        request.predicate = NSPredicate(format: "%K == YES", #keyPath(BookmarkEntity.isPendingDeletion))

        return (try? context.fetch(request)) ?? []
    }

    public static func fetchModifiedBookmarks(_ context: NSManagedObjectContext) -> [BookmarkEntity] {
        let request = BookmarkEntity.fetchRequest()
        request.predicate = NSPredicate(format: "%K != nil", #keyPath(BookmarkEntity.modifiedAt))

        return (try? context.fetch(request)) ?? []
    }

    // MARK: Internal

    @discardableResult
    static func insertRootFolder(uuid: String, into context: NSManagedObjectContext) -> BookmarkEntity {
        let folder = BookmarkEntity(entity: BookmarkEntity.entity(in: context),
                                    insertInto: context)
        folder.uuid = uuid
        folder.title = uuid
        folder.isFolder = true

        return folder
    }
}

// MARK: - Legacy Migration Support

extension BookmarkUtils {

    public static func prepareLegacyFoldersStructure(in context: NSManagedObjectContext) {

        if fetchRootFolder(context) == nil {
            insertRootFolder(uuid: BookmarkEntity.Constants.rootFolderID, into: context)
        }

        if fetchLegacyFavoritesFolder(context) == nil {
            insertRootFolder(uuid: legacyFavoritesFolderID, into: context)
        }
    }

    public static func fetchLegacyFavoritesFolder(_ context: NSManagedObjectContext) -> BookmarkEntity? {
        fetchFavoritesFolder(withUUID: legacyFavoritesFolderID, in: context)
    }

    static let legacyFavoritesFolderID = FavoritesFolderID.unified.rawValue
}
