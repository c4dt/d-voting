import { test, expect } from '@playwright/test';

test('Assert homepage title', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page).toHaveTitle(/D-Voting/);
});
