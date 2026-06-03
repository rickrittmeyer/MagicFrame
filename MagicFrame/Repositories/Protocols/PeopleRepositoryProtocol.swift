import Foundation

protocol PeopleRepositoryProtocol: AnyObject {
    func upsertPerson(name: String) -> Int
    func linkPhotoToPerson(photoId: String, personId: Int, source: String)
    func getAllPersonNames() -> [String]
}

extension PeopleRepository: PeopleRepositoryProtocol {}
