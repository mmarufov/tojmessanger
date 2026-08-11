import { beforeEach, describe, expect, test } from "bun:test";
import { makeSql } from "./db";
import {
  checkVerification,
  checkVerificationV2,
  completeSecurityStepUp,
  completeTwoFactorLogin,
  configureTwoFactor,
  regenerateTwoFactorRecoveryCodes,
  resolveDevice,
  startSecurityChange,
  startVerification,
  twoFactorStatus,
} from "./auth";
import { startCloudServer } from "./cloud";
import {
  ACCESS_TOKEN_TTL_MS,
  SESSION_ABSOLUTE_TTL_MS,
  issueV2Session,
  refreshV2Session,
  resolveV2Access,
  upgradeLegacySession,
} from "./session-security";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function legacyAccount(phone: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code!, "ios", "Security iPhone", "Alice");
}

describe("auth protocol v2 and two-step verification", () => {
  beforeEach(resetDb);

  test("refresh rotation is crash-safe and detects a different replay", async () => {
    const legacy = await legacyAccount("+16505557101");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    expect((await resolveDevice(db, upgraded.accessToken)).deviceId).toBe(legacy.deviceId);
    await expect(resolveDevice(db, legacy.token)).rejects.toMatchObject({ code: "device_revoked" });

    const rotationId = crypto.randomUUID();
    const rotated = await refreshV2Session(db, upgraded.refreshToken, rotationId);
    const recovered = await refreshV2Session(db, upgraded.refreshToken, rotationId);
    expect(recovered).toEqual(rotated);
    expect((await resolveDevice(db, rotated.accessToken)).accountId).toBe(legacy.accountId);

    await expect(refreshV2Session(db, upgraded.refreshToken, crypto.randomUUID()))
      .rejects.toMatchObject({ code: "refresh_reuse_detected" });
    await expect(resolveDevice(db, rotated.accessToken))
      .rejects.toMatchObject({ code: "refresh_reuse_detected" });
  });

  test("refresh rejects malformed and cross-generation rotation identifiers without mutation", async () => {
    const legacy = await legacyAccount("+16505557107");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    await expect(refreshV2Session(db, upgraded.refreshToken, "------------------------------------"))
      .rejects.toMatchObject({ status: 400, code: "invalid_rotation_id" });

    const rotationId = crypto.randomUUID();
    const first = await refreshV2Session(db, upgraded.refreshToken, rotationId);
    await expect(refreshV2Session(db, first.refreshToken, rotationId))
      .rejects.toMatchObject({ status: 409, code: "rotation_id_reused" });
    const recovered = await refreshV2Session(db, first.refreshToken, crypto.randomUUID());
    expect((await resolveDevice(db, recovered.accessToken)).deviceId).toBe(legacy.deviceId);
  });

  test("late receipts cannot roll credentials backward and in-place reissue fences prior access", async () => {
    const legacy = await legacyAccount("+16505557108");
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    const firstRotationId = crypto.randomUUID();
    const first = await refreshV2Session(db, upgraded.refreshToken, firstRotationId);
    const second = await refreshV2Session(db, first.refreshToken, crypto.randomUUID());

    await expect(refreshV2Session(db, upgraded.refreshToken, firstRotationId))
      .rejects.toMatchObject({ status: 409, code: "rotation_superseded" });
    await expect(resolveDevice(db, second.accessToken)).resolves.toMatchObject({
      deviceId: legacy.deviceId,
    });

    const reissued = await issueV2Session(db, {
      accountId: legacy.accountId,
      platform: "ios",
      existingDeviceId: legacy.deviceId,
    });
    await expect(resolveDevice(db, second.accessToken))
      .rejects.toMatchObject({ code: "device_revoked" });
    await expect(resolveDevice(db, reissued.accessToken)).resolves.toMatchObject({
      deviceId: legacy.deviceId,
    });
  });

  test("access and absolute expiry boundaries use the injected clock", async () => {
    const legacy = await legacyAccount("+16505557103");
    const base = new Date("2026-08-11T00:00:00.000Z");
    const session = await issueV2Session(db, {
      accountId: legacy.accountId,
      platform: "ios",
      existingDeviceId: legacy.deviceId,
      now: base,
    });
    await expect(resolveV2Access(
      db,
      session.accessToken,
      new Date(base.getTime() + ACCESS_TOKEN_TTL_MS - 1),
    )).resolves.toMatchObject({ deviceId: legacy.deviceId });
    await expect(resolveV2Access(
      db,
      session.accessToken,
      new Date(base.getTime() + ACCESS_TOKEN_TTL_MS),
    )).rejects.toMatchObject({ code: "access_token_expired" });
    await expect(refreshV2Session(
      db,
      session.refreshToken,
      crypto.randomUUID(),
      new Date(base.getTime() + SESSION_ABSOLUTE_TTL_MS),
    )).rejects.toMatchObject({ code: "session_expired" });
  });

  test("password login and SMS-bound recovery rotate codes and revoke older sessions", async () => {
    const phone = "+16505557102";
    const legacy = await legacyAccount(phone);
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);

    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    const enabled = await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "correct horse battery staple",
    });
    expect(enabled.recoveryCodes).toHaveLength(10);
    expect(await twoFactorStatus(db, legacy.accountId)).toEqual({
      enabled: true,
      recoveryCodesRemaining: 10,
    });
    await expect(resolveDevice(db, upgraded.accessToken)).rejects.toMatchObject({
      code: "device_revoked",
    });
    await expect(resolveDevice(db, enabled.session.accessToken)).resolves.toMatchObject({
      accountId: legacy.accountId,
    });

    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const nextOTP = await startVerification(db, phone);
    const challenge = await checkVerificationV2(
      db, phone, nextOTP.code!, "ios", "New iPhone", "Alice",
    );
    expect(challenge.state).toBe("two_factor_required");
    if (challenge.state !== "two_factor_required") throw new Error("expected challenge");
    await expect(completeTwoFactorLogin(db, {
      challengeId: challenge.challengeId,
      password: "wrong password",
    })).rejects.toMatchObject({ code: "incorrect_second_factor" });
    const signedIn = await completeTwoFactorLogin(db, {
      challengeId: challenge.challengeId,
      password: "correct horse battery staple",
    });
    expect(signedIn.session.tokenVersion).toBe(2);

    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const recoveryOTP = await startVerification(db, phone);
    const recoveryChallenge = await checkVerificationV2(
      db, phone, recoveryOTP.code!, "ios", "Recovered iPhone", "Alice",
    );
    if (recoveryChallenge.state !== "two_factor_required") throw new Error("expected challenge");
    const recovered = await completeTwoFactorLogin(db, {
      challengeId: recoveryChallenge.challengeId,
      recoveryCode: enabled.recoveryCodes[0],
      newPassword: "a completely different safe password",
    });
    expect(recovered.recoveryCodes).toHaveLength(10);
    expect(recovered.recoveryCodes).not.toEqual(enabled.recoveryCodes);
    await expect(resolveDevice(db, signedIn.session.accessToken))
      .rejects.toMatchObject({ code: "device_revoked" });
  });

  test("rollout rollback keeps enrolled login and issued refresh credentials usable", async () => {
    const originalAuth = process.env.TOJ_AUTH_SESSIONS_V2_ENABLED;
    const originalFactor = process.env.TOJ_TWO_FACTOR_ENABLED;
    process.env.TOJ_AUTH_SESSIONS_V2_ENABLED = "1";
    process.env.TOJ_TWO_FACTOR_ENABLED = "1";
    const phone = "+16505557109";
    const legacy = await legacyAccount(phone);
    const upgraded = await upgradeLegacySession(db, legacy.accountId, legacy.deviceId);
    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    const enabled = await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "rollback safe account password",
    });
    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const nextOTP = await startVerification(db, phone);

    process.env.TOJ_TWO_FACTOR_ENABLED = "0";
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    try {
      const base = `http://127.0.0.1:${server.port}`;
      const challengeResponse = await fetch(`${base}/v1/auth/check`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          phone,
          code: nextOTP.code,
          authProtocolVersion: 2,
          platform: "ios",
          deviceName: "Rollback iPhone",
        }),
      });
      expect(challengeResponse.status).toBe(200);
      const challenge = await challengeResponse.json() as any;
      expect(challenge.state).toBe("two_factor_required");
      const completion = await fetch(`${base}/v1/auth/two-factor/check`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          challengeId: challenge.challengeId,
          password: "rollback safe account password",
        }),
      });
      expect(completion.status).toBe(200);

      const capabilities = await fetch(`${base}/v1/capabilities`, {
        headers: { authorization: `Bearer ${enabled.session.accessToken}` },
      }).then((response) => response.json()) as any;
      expect(capabilities.capabilities).toContain("two_factor_v1");

      process.env.TOJ_AUTH_SESSIONS_V2_ENABLED = "0";
      const refresh = await fetch(`${base}/v1/session/refresh`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          refreshToken: enabled.session.refreshToken,
          rotationId: crypto.randomUUID(),
        }),
      });
      expect(refresh.status).toBe(200);
      expect((await refresh.json() as any).tokenVersion).toBe(2);
    } finally {
      await server.stop(true);
      if (originalAuth == null) delete process.env.TOJ_AUTH_SESSIONS_V2_ENABLED;
      else process.env.TOJ_AUTH_SESSIONS_V2_ENABLED = originalAuth;
      if (originalFactor == null) delete process.env.TOJ_TWO_FACTOR_ENABLED;
      else process.env.TOJ_TWO_FACTOR_ENABLED = originalFactor;
    }
  });

  test("security step-up locks on the fifth failed SMS attempt", async () => {
    const legacy = await legacyAccount("+16505557104");
    const security = await startSecurityChange(db, legacy.accountId);
    for (let attempt = 1; attempt < 5; attempt += 1) {
      await expect(completeSecurityStepUp(db, legacy.accountId, "000000"))
        .rejects.toMatchObject({ status: 401 });
    }
    await expect(completeSecurityStepUp(db, legacy.accountId, "000000"))
      .rejects.toMatchObject({ status: 429, code: "challenge_locked" });
    await expect(completeSecurityStepUp(db, legacy.accountId, security.code!))
      .rejects.toMatchObject({ status: 429, code: "challenge_locked" });
  });

  test("concurrent recovery consumes an old code exactly once", async () => {
    const phone = "+16505557105";
    const legacy = await legacyAccount(phone);
    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    const enabled = await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "concurrent recovery password",
    });

    async function makeChallenge(deviceName: string) {
      await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
      const otp = await startVerification(db, phone);
      const result = await checkVerificationV2(db, phone, otp.code!, "ios", deviceName, "Alice");
      if (result.state !== "two_factor_required") throw new Error("expected challenge");
      return result.challengeId;
    }

    const firstChallenge = await makeChallenge("Recovery A");
    const secondChallenge = await makeChallenge("Recovery B");
    const attempts = await Promise.allSettled([
      completeTwoFactorLogin(db, {
        challengeId: firstChallenge,
        recoveryCode: enabled.recoveryCodes[0],
        newPassword: "first replacement password",
      }),
      completeTwoFactorLogin(db, {
        challengeId: secondChallenge,
        recoveryCode: enabled.recoveryCodes[0],
        newPassword: "second replacement password",
      }),
    ]);
    expect(attempts.filter((attempt) => attempt.status === "fulfilled")).toHaveLength(1);
    expect(attempts.filter((attempt) => attempt.status === "rejected")).toHaveLength(1);
    expect(await twoFactorStatus(db, legacy.accountId)).toEqual({
      enabled: true,
      recoveryCodesRemaining: 10,
    });
  });

  test("recovery codes can be replaced without changing the password", async () => {
    const legacy = await legacyAccount("+16505557106");
    const security = await startSecurityChange(db, legacy.accountId);
    const stepUp = await completeSecurityStepUp(db, legacy.accountId, security.code!);
    const enabled = await configureTwoFactor(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: stepUp.stepUpToken,
      password: "password retained during regeneration",
    });

    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    const nextSecurity = await startSecurityChange(db, legacy.accountId);
    const nextStepUp = await completeSecurityStepUp(db, legacy.accountId, nextSecurity.code!);
    const regenerated = await regenerateTwoFactorRecoveryCodes(db, {
      accountId: legacy.accountId,
      currentDeviceId: legacy.deviceId,
      stepUpToken: nextStepUp.stepUpToken,
      currentCredential: "password retained during regeneration",
    });
    expect(regenerated.recoveryCodes).toHaveLength(10);
    expect(regenerated.recoveryCodes).not.toEqual(enabled.recoveryCodes);
    expect((await resolveDevice(db, regenerated.session.accessToken)).accountId)
      .toBe(legacy.accountId);
  });
});
