/** Versioned, offline denylist. Keep exact matching so leading/trailing spaces remain meaningful. */
export const COMMON_PASSWORD_BLOCKLIST_VERSION = 1;

export const COMMON_PASSWORDS_V1 = new Set([
  "00000000", "11111111", "12341234", "12345678", "123456789", "1234567890",
  "1q2w3e4r", "1qaz2wsx", "65432100", "87654321", "abcdefgh", "admin123",
  "baseball1", "basketball", "changeme", "computer", "dragon123", "football1",
  "freedom1", "hello123", "iloveyou", "letmein1", "letmein123", "login123",
  "master123", "monkey123", "mustang1", "password", "password1", "password12",
  "password123", "princess", "qwerty123", "qwertyuiop", "secret123", "shadow123",
  "sunshine", "superman", "tojpassword", "trustno1", "welcome1", "welcome123",
  "whatever", "zaq12wsx",
]);
