//
//  GalvaActor.swift
//  Galva
//
//  The SDK's single global actor.
//
//  Why one global actor:
//    • Public API entry points are fire-and-forget — they enqueue a Task
//      on this actor and return immediately. Callers don't deal with await.
//    • Internal state (SDKCore, IdentityStore, MessageQueue) is isolated
//      to this actor, eliminating data races without per-property locks.
//    • Heavy work (HTTP, SQLite) hops off into dedicated actors (Uploader,
//      SQLiteMessageStorage) so we don't serialize uploads through here.
//

@globalActor
public actor GalvaActor {
    /// The single GalvaActor instance. Not for direct use — annotate types
    /// with `@GalvaActor` instead.
    public static let shared = GalvaActor()
    private init() {}
}
