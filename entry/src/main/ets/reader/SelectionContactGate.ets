// Shared by the M1 native contact probe. No inactivity/readiness timers.
// Do not integrate in production until system-handle delivery is verified.
export class SelectionContactGate {
  private session: number = 0;
  private contacts: Set<number> = new Set();
  private revision: number = 0;
  private releasedRevision: number = -1;
  private requiresMenu: boolean = false;
  private menuReady: boolean = false;
  reset(session: number, requiresMenu: boolean = false): void {
    this.session = session;
    this.requiresMenu = requiresMenu;
    this.menuReady = false;
    this.contacts.clear();
    this.revision = 0;
    this.releasedRevision = -1;
  }
  down(session: number, id: number): void {
    if (session !== this.session) return;
    this.contacts.add(id);
    this.releasedRevision = -1;
  }
  changed(session: number, revision: number): void {
    if (session !== this.session || revision <= this.revision) return;
    this.revision = revision;
    // A release precedes some Web selection callbacks. It stays a real release.
    if (this.contacts.size === 0 && this.releasedRevision >= 0) this.releasedRevision = revision;
  }
  up(session: number, id: number): void {
    if (session !== this.session || !this.contacts.delete(id)) return;
    if (this.contacts.size === 0) this.releasedRevision = this.revision;
  }
  cancel(session: number): void {
    if (session !== this.session) return;
    this.contacts.clear();
    this.releasedRevision = -1;
    this.menuReady = false;
  }
  nativeMenuChanged(session: number, visible: boolean): void {
    if (session !== this.session) return;
    this.menuReady = visible;
    if (!visible) this.releasedRevision = -1;
    // API 21 onMenuShow is a native selection-presentation event. It covers
    // system-handle release that Web.onTouch does not receive. Device gate required.
    else if (this.contacts.size === 0) this.releasedRevision = this.revision;
  }
  canPublish(session: number, revision: number): boolean {
    return session === this.session && (!this.requiresMenu || this.menuReady) && this.contacts.size === 0 && revision > 0 &&
      revision === this.revision && revision === this.releasedRevision;
  }
}
