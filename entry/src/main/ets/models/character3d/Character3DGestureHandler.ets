// Character3DGestureHandler: 3D gesture state machine (pure logic, no ArkUI dependency)
// T-3D.5B: 3D gesture interaction enhancement
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'Char3DGesture';

export enum GestureState {
  Idle,
  SingleRotate,
  TwoFingerPending,
  TwoFingerTranslate,
  TwoFingerScale
}

export enum TouchPhase {
  Down,
  Move,
  Up,
  Cancel
}

export interface TouchPointData {
  id: number;
  x: number;
  y: number;
}

export interface GestureCallbacks {
  onRotate: (deltaYawDeg: number, deltaPitchDeg: number) => void;
  onSetOffset: (offsetX: number, offsetY: number) => void;
  onSetScale: (scale: number) => void;
  onGestureEnd: () => void;
}

export interface GestureConfigSnapshot {
  scale: number;
  offsetX: number;
  offsetY: number;
}

const BASE_ROTATION_FACTOR: number = 0.15;
const ROTATION_MAX_PER_EVENT_DEG: number = 30;
const ROTATION_DEAD_ZONE_PX: number = 2;
const TRANSLATE_THRESHOLD_PX: number = 14;
const SCALE_THRESHOLD_RATIO: number = 0.10;
const PAN_FACTOR: number = 0.8284;
const DEFAULT_VIEWPORT_HEIGHT: number = 1000;
const SCALE_MIN: number = 0.1;
const SCALE_MAX: number = 8.0;
const OFFSET_MIN: number = -5.0;
const OFFSET_MAX: number = 5.0;
const DEFAULT_ROTATION_SENSITIVITY: number = 1.0;
const SENSITIVITY_MIN: number = 0.2;
const SENSITIVITY_MAX: number = 2.0;

export class Character3DGestureHandler {
  private stateValue: GestureState = GestureState.Idle;
  private disposed: boolean = false;
  private callbacks: GestureCallbacks | null = null;
  private rotationSensitivity: number = DEFAULT_ROTATION_SENSITIVITY;
  private cameraDistance: number = 5.0;
  private viewportWidth: number = 0;
  private viewportHeight: number = DEFAULT_VIEWPORT_HEIGHT;
  private activePointers: Map<number, TouchPointData> = new Map<number, TouchPointData>();
  private lastX: number = 0;
  private lastY: number = 0;
  private primaryPointerId: number = -1;
  private startCenterX: number = 0;
  private startCenterY: number = 0;
  private startDistance: number = 0;
  private startScale: number = 1.0;
  private startOffsetX: number = 0;
  private startOffsetY: number = 0;
  private twoFingerId1: number = -1;
  private twoFingerId2: number = -1;
  private suppressSingleRotate: boolean = false;

  setCallbacks(callbacks: GestureCallbacks): void {
    this.callbacks = callbacks;
  }

  setRotationSensitivity(sensitivity: number): void {
    this.rotationSensitivity = sanitizeSensitivity(sensitivity);
  }

  setCameraDistance(distance: number): void {
    if (Number.isFinite(distance) && distance > 0) {
      this.cameraDistance = distance;
    }
  }

  setViewport(width: number, height: number): void {
    if (width > 0) {
      this.viewportWidth = width;
    }
    if (height > 0) {
      this.viewportHeight = height;
    }
  }

  updateCurrentConfig(_config: GestureConfigSnapshot): void {}

  updateCurrentPitch(_pitchDeg: number): void {}

  getState(): GestureState {
    return this.stateValue;
  }

  handleTouch(phase: TouchPhase, touches: TouchPointData[], changedId: number, currentConfig: GestureConfigSnapshot): void {
    if (this.disposed) {
      return;
    }
    this.updateActivePointers(phase, touches, changedId);
    const pointerCount: number = this.activePointers.size;
    if (phase === TouchPhase.Down) {
      this.handleDown(pointerCount, changedId, currentConfig);
    } else if (phase === TouchPhase.Move) {
      this.handleMove(pointerCount, currentConfig);
    } else if (phase === TouchPhase.Up) {
      this.handleUp(pointerCount, changedId, currentConfig);
    } else if (phase === TouchPhase.Cancel) {
      this.handleCancel();
    }
  }

  dispose(): void {
    this.disposed = true;
    this.stateValue = GestureState.Idle;
    this.callbacks = null;
    this.activePointers.clear();
    this.suppressSingleRotate = false;
    this.primaryPointerId = -1;
    this.twoFingerId1 = -1;
    this.twoFingerId2 = -1;
  }

  private updateActivePointers(phase: TouchPhase, touches: TouchPointData[], changedId: number): void {
    if (phase === TouchPhase.Cancel) {
      this.activePointers.clear();
      return;
    }
    if (phase === TouchPhase.Up && changedId >= 0) {
      this.activePointers.delete(changedId);
      return;
    }
    this.activePointers.clear();
    for (let i = 0; i < touches.length; i++) {
      const t: TouchPointData = touches[i];
      this.activePointers.set(t.id, t);
    }
  }

  private handleDown(pointerCount: number, changedId: number, currentConfig: GestureConfigSnapshot): void {
    if (pointerCount === 1) {
      if (this.suppressSingleRotate) {
        return;
      }
      const p: TouchPointData | undefined = this.activePointers.get(changedId);
      if (p === undefined) {
        return;
      }
      this.stateValue = GestureState.SingleRotate;
      this.primaryPointerId = changedId;
      this.lastX = p.x;
      this.lastY = p.y;
      Logger.debug(LOG_TAG, 'rotate start, pointer=' + changedId);
    } else if (pointerCount === 2) {
      this.endSingleRotate();
      this.startTwoFingerGesture(currentConfig);
    }
  }

  private handleMove(pointerCount: number, currentConfig: GestureConfigSnapshot): void {
    if (pointerCount === 1 && this.stateValue === GestureState.SingleRotate) {
      this.applySingleRotate();
    } else if (pointerCount >= 2) {
      this.applyTwoFingerGesture(currentConfig);
    }
  }

  private handleUp(pointerCount: number, _changedId: number, _currentConfig: GestureConfigSnapshot): void {
    if (pointerCount === 0) {
      this.endGesture();
      this.stateValue = GestureState.Idle;
      this.suppressSingleRotate = false;
      this.primaryPointerId = -1;
      this.twoFingerId1 = -1;
      this.twoFingerId2 = -1;
    } else if (pointerCount === 1) {
      if (this.stateValue === GestureState.TwoFingerPending
        || this.stateValue === GestureState.TwoFingerTranslate
        || this.stateValue === GestureState.TwoFingerScale) {
        this.endGesture();
        this.stateValue = GestureState.Idle;
        this.suppressSingleRotate = true;
        this.twoFingerId1 = -1;
        this.twoFingerId2 = -1;
      }
    }
  }

  private handleCancel(): void {
    this.endGesture();
    this.stateValue = GestureState.Idle;
    this.suppressSingleRotate = false;
    this.primaryPointerId = -1;
    this.twoFingerId1 = -1;
    this.twoFingerId2 = -1;
    this.activePointers.clear();
  }

  private applySingleRotate(): void {
    const p: TouchPointData | undefined = this.activePointers.get(this.primaryPointerId);
    if (p === undefined) {
      return;
    }
    const dx: number = p.x - this.lastX;
    const dy: number = p.y - this.lastY;
    this.lastX = p.x;
    this.lastY = p.y;
    if (Math.abs(dx) < ROTATION_DEAD_ZONE_PX && Math.abs(dy) < ROTATION_DEAD_ZONE_PX) {
      return;
    }
    let deltaYaw: number = dx * this.rotationSensitivity * BASE_ROTATION_FACTOR;
    let deltaPitch: number = dy * this.rotationSensitivity * BASE_ROTATION_FACTOR;
    deltaYaw = clampDeg(deltaYaw, ROTATION_MAX_PER_EVENT_DEG);
    deltaPitch = clampDeg(deltaPitch, ROTATION_MAX_PER_EVENT_DEG);
    if (this.callbacks !== null) {
      this.callbacks.onRotate(deltaYaw, deltaPitch);
    }
  }

  private endSingleRotate(): void {
    if (this.stateValue === GestureState.SingleRotate) {
      this.stateValue = GestureState.Idle;
      this.primaryPointerId = -1;
    }
  }

  private startTwoFingerGesture(currentConfig: GestureConfigSnapshot): void {
    const ids: number[] = Array.from(this.activePointers.keys());
    if (ids.length < 2) {
      return;
    }
    this.twoFingerId1 = ids[0];
    this.twoFingerId2 = ids[1];
    const p1: TouchPointData | undefined = this.activePointers.get(this.twoFingerId1);
    const p2: TouchPointData | undefined = this.activePointers.get(this.twoFingerId2);
    if (p1 === undefined || p2 === undefined) {
      return;
    }
    this.startCenterX = (p1.x + p2.x) / 2;
    this.startCenterY = (p1.y + p2.y) / 2;
    this.startDistance = distance(p1.x, p1.y, p2.x, p2.y);
    this.startScale = currentConfig.scale;
    this.startOffsetX = currentConfig.offsetX;
    this.startOffsetY = currentConfig.offsetY;
    this.stateValue = GestureState.TwoFingerPending;
    Logger.debug(LOG_TAG, 'two-finger start, dist=' + this.startDistance.toFixed(1));
  }

  private applyTwoFingerGesture(_currentConfig: GestureConfigSnapshot): void {
    const p1: TouchPointData | undefined = this.activePointers.get(this.twoFingerId1);
    const p2: TouchPointData | undefined = this.activePointers.get(this.twoFingerId2);
    if (p1 === undefined || p2 === undefined) {
      return;
    }
    const currentCenterX: number = (p1.x + p2.x) / 2;
    const currentCenterY: number = (p1.y + p2.y) / 2;
    const currentDist: number = distance(p1.x, p1.y, p2.x, p2.y);
    if (this.stateValue === GestureState.TwoFingerPending) {
      this.resolveTwoFingerMode(currentCenterX, currentCenterY, currentDist);
      return;
    }
    if (this.stateValue === GestureState.TwoFingerTranslate) {
      this.applyTwoFingerTranslate(currentCenterX, currentCenterY);
    } else if (this.stateValue === GestureState.TwoFingerScale) {
      this.applyTwoFingerScale(currentDist);
    }
  }

  private resolveTwoFingerMode(currentCenterX: number, currentCenterY: number, currentDist: number): void {
    const dx: number = currentCenterX - this.startCenterX;
    const dy: number = currentCenterY - this.startCenterY;
    const translateMag: number = Math.sqrt(dx * dx + dy * dy);
    const scaleRatio: number = this.startDistance > 0 ? Math.abs(currentDist / this.startDistance - 1) : 0;
    if (scaleRatio > SCALE_THRESHOLD_RATIO) {
      this.stateValue = GestureState.TwoFingerScale;
      Logger.debug(LOG_TAG, 'lock scale, ratio=' + scaleRatio.toFixed(3));
      return;
    }
    if (translateMag > TRANSLATE_THRESHOLD_PX && scaleRatio < SCALE_THRESHOLD_RATIO) {
      this.stateValue = GestureState.TwoFingerTranslate;
      Logger.debug(LOG_TAG, 'lock translate, mag=' + translateMag.toFixed(1));
      return;
    }
  }

  private applyTwoFingerTranslate(currentCenterX: number, currentCenterY: number): void {
    const deltaCenterX: number = currentCenterX - this.startCenterX;
    const deltaCenterY: number = currentCenterY - this.startCenterY;
    const worldPerPixel: number = this.cameraDistance * PAN_FACTOR / this.viewportHeight;
    const newOffsetX: number = clampOffset(this.startOffsetX + deltaCenterX * worldPerPixel);
    const newOffsetY: number = clampOffset(this.startOffsetY - deltaCenterY * worldPerPixel);
    if (this.callbacks !== null) {
      this.callbacks.onSetOffset(newOffsetX, newOffsetY);
    }
  }

  private applyTwoFingerScale(currentDist: number): void {
    if (this.startDistance <= 0) {
      return;
    }
    const ratio: number = currentDist / this.startDistance;
    const newScale: number = clampScale(this.startScale * ratio);
    if (this.callbacks !== null) {
      this.callbacks.onSetScale(newScale);
    }
  }

  private endGesture(): void {
    if (this.stateValue === GestureState.Idle) {
      return;
    }
    Logger.debug(LOG_TAG, 'gesture end, state=' + this.stateValue);
    if (this.callbacks !== null) {
      this.callbacks.onGestureEnd();
    }
  }
}

function distance(x1: number, y1: number, x2: number, y2: number): number {
  const dx: number = x2 - x1;
  const dy: number = y2 - y1;
  return Math.sqrt(dx * dx + dy * dy);
}

function clampDeg(value: number, maxAbs: number): number {
  if (value > maxAbs) {
    return maxAbs;
  }
  if (value < -maxAbs) {
    return -maxAbs;
  }
  return value;
}

function clampScale(scale: number): number {
  if (!Number.isFinite(scale)) {
    return SCALE_MIN;
  }
  if (scale < SCALE_MIN) {
    return SCALE_MIN;
  }
  if (scale > SCALE_MAX) {
    return SCALE_MAX;
  }
  return scale;
}

function clampOffset(offset: number): number {
  if (!Number.isFinite(offset)) {
    return 0;
  }
  if (offset < OFFSET_MIN) {
    return OFFSET_MIN;
  }
  if (offset > OFFSET_MAX) {
    return OFFSET_MAX;
  }
  return offset;
}

function sanitizeSensitivity(sensitivity: number): number {
  if (!Number.isFinite(sensitivity) || sensitivity <= 0) {
    return DEFAULT_ROTATION_SENSITIVITY;
  }
  if (sensitivity < SENSITIVITY_MIN) {
    return SENSITIVITY_MIN;
  }
  if (sensitivity > SENSITIVITY_MAX) {
    return SENSITIVITY_MAX;
  }
  return sensitivity;
}
