import { beforeEach, describe, expect, test } from "bun:test";
import { makeSql } from "./db";
import {
  checkVerification,
  checkVerificationV2,
  completeSecurityStepUp,
  completeTwoFactorLogin,
  configureTwoFactor,
  resolveDevice,
  startSecurityChange,
  startVerification,
  twoFactorStatus,
} from "./auth";
import { refreshV2Session, upgradeLegacySession } from "./session-security";

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
    await expect(resolveDevice(db, upgraded.accessToken)).resolves.toMatchObject({
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
});
