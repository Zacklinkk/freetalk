// Verify published artifacts against the public key shipped in the application.
// No private key is needed or read by this check.
import Foundation
import CryptoKit

enum VerificationFailure: Error { case invalid(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationFailure.invalid(message) }
}
let arguments = CommandLine.arguments
try require(arguments.count == 4, "Expected Info.plist, appcast.xml and archive paths")
let info = try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:arguments[1])),format:nil) as! [String:Any]
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:Data(base64Encoded:info["SUPublicEDKey"] as! String)!)
let feed = try Data(contentsOf:URL(fileURLWithPath:arguments[2]))
let feedText = String(decoding:feed,as:UTF8.self)
let pattern = #"<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*$"#
let regex = try NSRegularExpression(pattern:pattern)
guard let match = regex.firstMatch(in:feedText,range:NSRange(feedText.startIndex...,in:feedText)),
      let signatureRange = Range(match.range(at:1),in:feedText),
      let lengthRange = Range(match.range(at:2),in:feedText),
      let signature = Data(base64Encoded:String(feedText[signatureRange])),
      let length = Int(feedText[lengthRange]), length <= feed.count else {
    throw VerificationFailure.invalid("Missing signed feed trailer")
}
try require(publicKey.isValidSignature(signature,for:feed.prefix(length)), "Feed signature does not match the application's public key")
let xml = try XMLDocument(data:feed,options:[])
let archiveURL = URL(fileURLWithPath:arguments[3])
let archive = try Data(contentsOf:archiveURL)
let enclosures = try xml.nodes(forXPath:"//enclosure").compactMap { $0 as? XMLElement }.filter {
    URL(string:$0.attribute(forName:"url")?.stringValue ?? "")?.lastPathComponent == archiveURL.lastPathComponent
}
try require(enclosures.count == 1, "Expected one enclosure for this archive")
let enclosure = enclosures[0]
let archiveSignature = Data(base64Encoded:enclosure.attribute(forName:"sparkle:edSignature")?.stringValue ?? "") ?? Data()
try require(Int(enclosure.attribute(forName:"length")?.stringValue ?? "") == archive.count, "Archive length differs from feed")
try require(publicKey.isValidSignature(archiveSignature,for:archive), "Archive signature does not match the application's public key")
print("Feed and archive signatures match the application's public key.")
