import accessibility from '@ohos.accessibility';
import deviceInfo from '@ohos.deviceInfo';

// Both modules already exist on API21. Only their API23 members are accessed
// within the runtime/API/syscap branch. No new native module or eager value.
class SystemMotionObserver {
  private registered: boolean = false;
  private handler: (reduced: boolean | undefined) => void;
  private changed = (reduced: boolean): void => { this.handler(reduced); };
  constructor(handler: (reduced: boolean | undefined) => void) { this.handler = handler; }
  start(): void {
    this.handler(undefined);
    try {
      if (deviceInfo.sdkApiVersion >= 23) {
        if (deviceInfo.apiAvailable(23)) {
          if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
            this.handler(accessibility.isAnimationReduceEnabledSync());
            accessibility.onAnimationReduceStateChange(this.changed);
            this.registered = true;
          }
        }
      }
    } catch (_) { this.handler(undefined); }
  }
  stop(): void {
    if (!this.registered) return;
    try {
      if (deviceInfo.sdkApiVersion >= 23) {
        if (deviceInfo.apiAvailable(23)) {
          if (canIUse('SystemCapability.BarrierFree.Accessibility.Core')) accessibility.offAnimationReduceStateChange(this.changed);
        }
      }
    } catch (_) {}
    this.registered = false;
  }
}
export function observeSystemMotion(handler: (reduced: boolean | undefined) => void): () => void {
  const observer = new SystemMotionObserver(handler);
  observer.start();
  return (): void => observer.stop();
}
