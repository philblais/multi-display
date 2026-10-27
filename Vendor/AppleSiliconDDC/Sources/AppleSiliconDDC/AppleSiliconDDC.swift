//  Copyright © @waydabber

import AppleSiliconDDCObjC
import Foundation
import IOKit

let ARM64_DDC_7BIT_ADDRESS: UInt8 = 0x37 // This works with DisplayPort devices
let ARM64_DDC_DATA_ADDRESS: UInt8 = 0x51

public class AppleSiliconDDC: NSObject {
  #if arch(arm64)
    public static let isArm64: Bool = true
  #else
    public static let isArm64: Bool = false
  #endif
  public struct IOregService {
    public var edidUUID: String = ""
    public var manufacturerID: String = ""
    public var productName: String = ""
    public var serialNumber: Int64 = 0
    public var alphanumericSerialNumber: String = ""
    public var location: String = ""
    public var ioDisplayLocation: String = ""
    public var transportUpstream: String = ""
    public var transportDownstream: String = ""
    public var service: IOAVService?
    public var serviceLocation: Int = 0
    public var displayAttributes: NSDictionary?
  }

  public struct Arm64Service {
    var displayID: CGDirectDisplayID = 0
    var service: IOAVService?
    var serviceLocation: Int = 0
    var discouraged: Bool = false
    var dummy: Bool = false
    var serviceDetails: IOregService
    var matchScore: Int = 0
  }

  static func getServiceMatches(displayIDs: [CGDirectDisplayID]) -> [Arm64Service] {
    let services = getIoregServicesForMatching()
    // Treat multiple proxy records for one framebuffer as ambiguous rather than choosing one.
    let locationCounts = Dictionary(grouping: services.filter { $0.service != nil }, by: \.serviceLocation).mapValues(\.count)
    let scores: [[Int?]] = displayIDs.map { displayID in
      services.map { service in
        guard service.service != nil, locationCounts[service.serviceLocation] == 1 else { return nil }
        return ioregMatchScore(displayID: displayID, ioregEdidUUID: service.edidUUID, ioDisplayLocation: service.ioDisplayLocation, ioregProductName: service.productName, ioregSerialNumber: service.serialNumber, serviceLocation: service.serviceLocation)
      }
    }
    return unambiguousMatches(scores: scores).map { match in
      let service = services[match.serviceIndex]
      return Arm64Service(displayID: displayIDs[match.displayIndex], service: service.service, serviceLocation: service.serviceLocation, discouraged: checkIfDiscouraged(ioregService: service), dummy: checkIfDummy(ioregService: service), serviceDetails: service, matchScore: scores[match.displayIndex][match.serviceIndex] ?? 0)
    }
  }

  // A route must be the unique positive best match from both ends. Nil means no usable service.
  // Equal scores cannot safely distinguish identical monitors, regardless of enumeration order.
  static func unambiguousMatches(scores: [[Int?]]) -> [(displayIndex: Int, serviceIndex: Int)] {
    func uniqueBestIndex(_ values: [Int?]) -> Int? {
      guard let bestScore = values.compactMap({ $0 }).filter({ $0 > 0 }).max() else { return nil }
      let matches = values.indices.filter { values[$0] == bestScore }
      return matches.count == 1 ? matches[0] : nil
    }
    return scores.indices.compactMap { displayIndex in
      guard let serviceIndex = uniqueBestIndex(scores[displayIndex]) else { return nil }
      let serviceScores = scores.map { row in row.indices.contains(serviceIndex) ? row[serviceIndex] : nil }
      guard uniqueBestIndex(serviceScores) == displayIndex else { return nil }
      return (displayIndex, serviceIndex)
    }
  }

  static public func read(service: IOAVService?, command: UInt8, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> (current: UInt16, max: UInt16)? {
    var send: [UInt8] = [command]
    var reply = [UInt8](repeating: 0, count: 11)
    guard Self.performDDCCommunication(service: service, send: &send, reply: &reply, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, readSleepTime: readSleepTime, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime) else {
      return nil
    }
    return decodeVCPReply(reply, command: command)
  }

  static public func write(service: IOAVService?, command: UInt8, value: UInt16, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> Bool {
    var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 255)]
    var reply: [UInt8] = []
    return Self.performDDCCommunication(service: service, send: &send, reply: &reply, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime)
  }

  static func performDDCCommunication(service: IOAVService?, send: inout [UInt8], reply: inout [UInt8], writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> Bool {
    guard let service else { return false }
    return performDDCCommunication(send: &send, reply: &reply, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, readSleepTime: readSleepTime, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime, writePacket: { packet in
      IOAVServiceWriteI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(ARM64_DDC_DATA_ADDRESS), &packet, UInt32(packet.count)) == 0
    }, readReply: { buffer in
      IOAVServiceReadI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(ARM64_DDC_DATA_ADDRESS), &buffer, UInt32(buffer.count)) == 0
    }, sleep: { usleep($0) })
  }

  // Keep packet validation and retries independent of IOKit so failures can be tested safely.
  static func performDDCCommunication(send: inout [UInt8], reply: inout [UInt8], writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil, writePacket: (inout [UInt8]) -> Bool, readReply: (inout [UInt8]) -> Bool, sleep: (UInt32) -> Void) -> Bool {
    guard send.count == 1 || send.count == 3 else { return false }
    let expectsReply = !reply.isEmpty
    guard !expectsReply || (send.count == 1 && reply.count == 11) else { return false }
    var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send
    let checksumSeed = send.count == 1 ? ARM64_DDC_7BIT_ADDRESS << 1 : ARM64_DDC_7BIT_ADDRESS << 1 ^ ARM64_DDC_DATA_ADDRESS
    packet.append(checksum(seed: checksumSeed, data: packet))
    let attempts = Int(numOfRetryAttemps ?? 4) + 1
    let writeCycles = max(Int(numOfWriteCycles ?? 2), 1)
    for attempt in 0 ..< attempts {
      // A failed or short read must never reuse bytes from a previous attempt.
      if expectsReply { reply = [UInt8](repeating: 0, count: 11) }
      var writeSucceeded = false
      for _ in 0 ..< writeCycles {
        sleep(writeSleepTime ?? 10000)
        writeSucceeded = writePacket(&packet)
      }
      if writeSucceeded {
        if !expectsReply { return true }
        sleep(readSleepTime ?? 50000)
        if readReply(&reply), decodeVCPReply(reply, command: send[0]) != nil {
          return true
        }
      }
      if attempt + 1 < attempts { sleep(retrySleepTime ?? 20000) }
    }
    if expectsReply { reply = [UInt8](repeating: 0, count: 11) }
    return false
  }

  static func decodeVCPReply(_ reply: [UInt8], command: UInt8) -> (current: UInt16, max: UInt16)? {
    // Get VCP reply: source, length, opcode, status, VCP code, type, max, current, checksum.
    guard reply.count == 11, reply[0] == ARM64_DDC_7BIT_ADDRESS << 1,
          reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0, reply[4] == command,
          checksum(seed: 0x50, data: Array(reply.dropLast())) == reply.last else {
      return nil
    }
    let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
    let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
    return (current, maximum)
  }

  static func checksum(seed: UInt8, data: [UInt8]) -> UInt8 {
    data.reduce(seed, ^)
  }

  static func ioregMatchScore(displayID: CGDirectDisplayID, ioregEdidUUID: String, ioDisplayLocation: String = "", ioregProductName: String = "", ioregSerialNumber: Int64 = 0, serviceLocation _: Int = 0) -> Int {
    var matchScore = 0
    if let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary? {
      if let kDisplayYearOfManufacture = dictionary[kDisplayYearOfManufacture] as? Int64, let kDisplayWeekOfManufacture = dictionary[kDisplayWeekOfManufacture] as? Int64, let kDisplayVendorID = dictionary[kDisplayVendorID] as? Int64, let kDisplayProductID = dictionary[kDisplayProductID] as? Int64, let kDisplayVerticalImageSize = dictionary[kDisplayVerticalImageSize] as? Int64, let kDisplayHorizontalImageSize = dictionary[kDisplayHorizontalImageSize] as? Int64 {
        struct KeyLoc {
          var key: String
          var loc: Int
        }
        let edidUUIDSearchKeys: [KeyLoc] = [
          // Vendor ID
          KeyLoc(key: String(format: "%04x", UInt16(max(0, min(kDisplayVendorID, 256 * 256 - 1)))).uppercased(), loc: 0),
          // Product ID
          KeyLoc(key: String(format: "%02x", UInt8((UInt16(max(0, min(kDisplayProductID, 256 * 256 - 1))) >> (0 * 8)) & 0xFF)).uppercased()
            + String(format: "%02x", UInt8((UInt16(max(0, min(kDisplayProductID, 256 * 256 - 1))) >> (1 * 8)) & 0xFF)).uppercased(), loc: 4),
          // Manufacture date
          KeyLoc(key: String(format: "%02x", UInt8(max(0, min(kDisplayWeekOfManufacture, 256 - 1)))).uppercased()
            + String(format: "%02x", UInt8(max(0, min(kDisplayYearOfManufacture - 1990, 256 - 1)))).uppercased(), loc: 19),
          // Image size
          KeyLoc(key: String(format: "%02x", UInt8(max(0, min(kDisplayHorizontalImageSize / 10, 256 - 1)))).uppercased()
            + String(format: "%02x", UInt8(max(0, min(kDisplayVerticalImageSize / 10, 256 - 1)))).uppercased(), loc: 30),
        ]
        for searchKey in edidUUIDSearchKeys where searchKey.key != "0000" && searchKey.key == ioregEdidUUID.prefix(searchKey.loc + 4).suffix(4) {
          matchScore += 1
        }
      }
      if ioDisplayLocation != "", let kIODisplayLocation = dictionary[kIODisplayLocationKey] as? String, ioDisplayLocation == kIODisplayLocation {
        matchScore += 10
      }
      if ioregProductName != "", let nameList = dictionary["DisplayProductName"] as? [String: String], let name = nameList["en_US"] ?? nameList.first?.value, name.lowercased() == ioregProductName.lowercased() {
        matchScore += 1
      }
      if ioregSerialNumber != 0, let serial = dictionary[kDisplaySerialNumber] as? Int64, serial == ioregSerialNumber {
        matchScore += 1
      }
    }
    return matchScore
  }

  // The caller owns each returned entry and must release it after use.
  static func ioregIterateToNextObjectOfInterest(interests: [String], iterator: inout io_iterator_t) -> (name: String, entry: io_service_t)? {
    let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer {
      name.deallocate()
    }
    while true {
      let entry = IOIteratorNext(iterator)
      guard entry != IO_OBJECT_NULL else { return nil }
      if IORegistryEntryGetName(entry, name) == KERN_SUCCESS {
        let nameString = String(cString: name)
        if interests.contains(where: { nameString.contains($0) }) {
          return (nameString, entry)
        }
      }
      IOObjectRelease(entry)
    }
  }

  static func getIORegServiceAppleCDC2Properties(entry: io_service_t) -> IOregService {
    var ioregService = IOregService()
    if let unmanagedEdidUUID = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let edidUUID = unmanagedEdidUUID.takeRetainedValue() as? String {
      ioregService.edidUUID = edidUUID
    }
    let cpath = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
    defer { cpath.deallocate() }
    if IORegistryEntryGetPath(entry, kIOServicePlane, cpath) == KERN_SUCCESS {
      ioregService.ioDisplayLocation = String(cString: cpath)
    }
    if let unmanagedDisplayAttrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let displayAttrs = unmanagedDisplayAttrs.takeRetainedValue() as? NSDictionary {
      ioregService.displayAttributes = displayAttrs
      if let productAttrs = displayAttrs.value(forKey: "ProductAttributes") as? NSDictionary {
        if let manufacturerID = productAttrs.value(forKey: "ManufacturerID") as? String {
          ioregService.manufacturerID = manufacturerID
        }
        if let productName = productAttrs.value(forKey: "ProductName") as? String {
          ioregService.productName = productName
        }
        if let serialNumber = productAttrs.value(forKey: "SerialNumber") as? Int64 {
          ioregService.serialNumber = serialNumber
        }
        if let alphanumericSerialNumber = productAttrs.value(forKey: "AlphanumericSerialNumber") as? String {
          ioregService.alphanumericSerialNumber = alphanumericSerialNumber
        }
      }
    }
    if let unmanagedTransport = IORegistryEntryCreateCFProperty(entry, "Transport" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let transport = unmanagedTransport.takeRetainedValue() as? NSDictionary {
      if let upstream = transport.value(forKey: "Upstream") as? String {
        ioregService.transportUpstream = upstream
      }
      if let downstream = transport.value(forKey: "Downstream") as? String {
        ioregService.transportDownstream = downstream
      }
    }
    return ioregService
  }

  static func setIORegServiceDCPAVServiceProxy(entry: io_service_t, ioregService: inout IOregService) {
    ioregService.service = nil
    ioregService.location = ""
    if let unmanagedLocation = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let location = unmanagedLocation.takeRetainedValue() as? String {
      ioregService.location = location
      if location == "External" {
        ioregService.service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() as IOAVService
      }
    }
  }

  static public func getIoregServicesForMatching() -> [IOregService] {
    var serviceLocation = 0
    var ioregServicesForMatching: [IOregService] = []
    let ioregRoot: io_registry_entry_t = IORegistryGetRootEntry(kIOMainPortDefault)
    defer {
      IOObjectRelease(ioregRoot)
    }
    var iterator = io_iterator_t()
    defer {
      IOObjectRelease(iterator)
    }
    var ioregService = IOregService()
    guard IORegistryEntryCreateIterator(ioregRoot, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
      return ioregServicesForMatching
    }
    let keyDCPAVServiceProxy = "DCPAVServiceProxy"
    let keysFramebuffer = ["AppleCLCD2", "IOMobileFramebufferShim"]
    while true {
      guard let objectOfInterest = ioregIterateToNextObjectOfInterest(interests: [keyDCPAVServiceProxy] + keysFramebuffer, iterator: &iterator) else {
        break
      }
      defer { IOObjectRelease(objectOfInterest.entry) }
      if keysFramebuffer.contains(objectOfInterest.name) {
        ioregService = self.getIORegServiceAppleCDC2Properties(entry: objectOfInterest.entry)
        serviceLocation += 1
        ioregService.serviceLocation = serviceLocation
      } else if objectOfInterest.name == keyDCPAVServiceProxy {
        self.setIORegServiceDCPAVServiceProxy(entry: objectOfInterest.entry, ioregService: &ioregService)
        ioregServicesForMatching.append(ioregService)
      }
    }
    return ioregServicesForMatching
  }

  static func checkIfDummy(ioregService: IOregService) -> Bool {
    if ioregService.manufacturerID == "AOC", ioregService.productName == "28E850" {
      return true
    }
    return false
  }

  static func checkIfDiscouraged(ioregService _: IOregService) -> Bool {
    false
  }
}
