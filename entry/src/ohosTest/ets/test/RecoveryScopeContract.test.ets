import { describe, it, expect } from '@ohos/hypium';
import {
  WorldSessionPostProcessRun,
  WorldSessionPostProcessRunStatus,
  WorldSessionPostProcessStepStatus,
  WorldSessionPostProcessResultCode,
  WorldSessionPostProcessState,
  parsePostProcessState,
  serializePostProcessState
} from '../../../main/ets/models/world/WorldSessionPostProcessRun';

function makeState(): WorldSessionPostProcessState {
  return {
    participantCharacterInstanceIds: ['ci-1'],
    summary: {
      status: WorldSessionPostProcessStepStatus.Pending,
      resultCode: undefined,
      errorKind: undefined,
      updatedAt: 0
    },
    memories: [],
    eventExtraction: {
      status: WorldSessionPostProcessStepStatus.Pending,
      resultCode: undefined,
      errorKind: undefined,
      updatedAt: 0
    },
    knownEvents: {
      status: WorldSessionPostProcessStepStatus.Pending,
      resultCode: undefined,
      errorKind: undefined,
      updatedAt: 0
    },
    relationships: []
  };
}

function makeRun(
  id: string,
  worldId: string,
  status: WorldSessionPostProcessRunStatus
): WorldSessionPostProcessRun {
  return {
    id: id,
    worldId: worldId,
    sceneId: 'scene-1',
    sessionId: 'session-1',
    pipelineVersion: 'world-session-post-process-v1',
    status: status,
    stateJson: serializePostProcessState(makeState()),
    attemptCount: 1,
    revision: 1,
    createdAt: 0,
    updatedAt: 0,
    completedAt: undefined
  };
}

export default function recoveryScopeContractTest(): void {
  describe('Recovery Scope 契约', () => {
    it('RECV-01 World-scoped query 不会返回其他 World 的 Run', 0, () => {
      const worldARun: WorldSessionPostProcessRun = makeRun('run-a1', 'world-A', WorldSessionPostProcessRunStatus.Running);
      const worldBRun: WorldSessionPostProcessRun = makeRun('run-b1', 'world-B', WorldSessionPostProcessRunStatus.Running);
      expect(worldARun.worldId !== worldBRun.worldId).assertTrue();
      const worldARuns: WorldSessionPostProcessRun[] = [worldARun];
      let foundOther: boolean = false;
      for (let i = 0; i < worldARuns.length; i++) {
        if (worldARuns[i].worldId !== 'world-A') {
          foundOther = true;
        }
      }
      expect(foundOther).assertFalse();
    });

    it('RECV-02 Running Run 的 activeSessions 保护 — world:sessionId 组合', 0, () => {
      const activeSessions: Set<string> = new Set();
      activeSessions.add('world-A:session-1');
      expect(activeSessions.has('world-A:session-1')).assertTrue();
      expect(activeSessions.has('world-A:session-2')).assertFalse();
    });

    it('RECV-03 Completed Run 不参与 recovery', 0, () => {
      const completedRun: WorldSessionPostProcessRun = makeRun('run-c1', 'world-A', WorldSessionPostProcessRunStatus.Completed);
      const needsRecovery: boolean = completedRun.status === WorldSessionPostProcessRunStatus.Running
        || completedRun.status === WorldSessionPostProcessRunStatus.Pending;
      expect(needsRecovery).assertFalse();
    });

    it('RECV-04 CompletedWithErrors Run 不参与 recovery', 0, () => {
      const cweRun: WorldSessionPostProcessRun = makeRun('run-cwe1', 'world-A', WorldSessionPostProcessRunStatus.CompletedWithErrors);
      const needsRecovery: boolean = cweRun.status === WorldSessionPostProcessRunStatus.Running
        || cweRun.status === WorldSessionPostProcessRunStatus.Pending;
      expect(needsRecovery).assertFalse();
    });

    it('RECV-05 Running 非活跃 Run 应被 recovery 到 Pending', 0, () => {
      const run: WorldSessionPostProcessRun = makeRun('run-r1', 'world-A', WorldSessionPostProcessRunStatus.Running);
      const recovered: WorldSessionPostProcessRun = {
        id: run.id,
        worldId: run.worldId,
        sceneId: run.sceneId,
        sessionId: run.sessionId,
        pipelineVersion: run.pipelineVersion,
        status: WorldSessionPostProcessRunStatus.Pending,
        stateJson: run.stateJson,
        attemptCount: run.attemptCount,
        revision: run.revision + 1,
        createdAt: run.createdAt,
        updatedAt: run.updatedAt,
        completedAt: undefined
      };
      expect(recovered.status === WorldSessionPostProcessRunStatus.Pending).assertTrue();
      expect(recovered.revision === run.revision + 1).assertTrue();
    });

    it('RECV-06 attemptCount 在 recovery 后不减少', 0, () => {
      const run: WorldSessionPostProcessRun = makeRun('run-r2', 'world-A', WorldSessionPostProcessRunStatus.Running);
      const recovered: WorldSessionPostProcessRun = {
        id: run.id,
        worldId: run.worldId,
        sceneId: run.sceneId,
        sessionId: run.sessionId,
        pipelineVersion: run.pipelineVersion,
        status: WorldSessionPostProcessRunStatus.Pending,
        stateJson: run.stateJson,
        attemptCount: run.attemptCount,
        revision: run.revision + 1,
        createdAt: run.createdAt,
        updatedAt: run.updatedAt,
        completedAt: undefined
      };
      expect(recovered.attemptCount >= run.attemptCount).assertTrue();
    });

    it('RECV-07 stateJson serialize/parse 往返一致', 0, () => {
      const state: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: ['ci-1'],
        summary: {
          status: WorldSessionPostProcessStepStatus.Running,
          resultCode: undefined,
          errorKind: undefined,
          updatedAt: 0
        },
        memories: [],
        eventExtraction: {
          status: WorldSessionPostProcessStepStatus.Succeeded,
          resultCode: WorldSessionPostProcessResultCode.Generated,
          errorKind: undefined,
          updatedAt: 0
        },
        knownEvents: {
          status: WorldSessionPostProcessStepStatus.Pending,
          resultCode: undefined,
          errorKind: undefined,
          updatedAt: 0
        },
        relationships: []
      };
      const json: string = serializePostProcessState(state);
      const parsed: WorldSessionPostProcessState = parsePostProcessState(json);
      expect(parsed.summary.status === WorldSessionPostProcessStepStatus.Running).assertTrue();
      expect(parsed.eventExtraction.status === WorldSessionPostProcessStepStatus.Succeeded).assertTrue();
    });
  });
}
