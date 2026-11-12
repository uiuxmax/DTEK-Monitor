import Foundation
import Darwin

enum MonitorProfile {
    static func open() throws -> String {
        #if DTEKMONITOR_MAC_TEST_BUILD
        let env=ProcessInfo.processInfo.environment
        guard TestEnvelope.isValid(env),let profile=env["DTEKMONITOR_TEST_PROFILE"] else {
            throw NSError(domain:"MonitorProfile",code:64)
        }
        return profile
        #else
        guard let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else {
            throw NSError(domain:"MonitorProfile",code:1)
        }
        // The personal Mac profile is separate from the protected test bundle
        // and Windows. No profile/environment/import override exists here.
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let profile=base.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("local.dtekmonitor.Monitor",isDirectory:true)
        let made=profile.path.withCString { mkdir($0,0o700) }
        guard made==0 || errno==EEXIST else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        let directory=profile.path.withCString { Darwin.open($0,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC) }
        guard directory>=0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        defer { Darwin.close(directory) }
        var info=stat()
        guard fstat(directory,&info)==0,info.st_uid==geteuid(),
              profile.standardizedFileURL.resolvingSymlinksInPath().path==profile.path else {
            throw NSError(domain:"MonitorProfile",code:2)
        }
        return profile.path
        #endif
    }
}
