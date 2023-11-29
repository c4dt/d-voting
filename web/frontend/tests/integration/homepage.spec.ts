import { test, expect } from '@playwright/test';
import { getFooter } from './footer.spec';

test('Assert homepage has correct title', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page).toHaveTitle(/D-Voting/);
});

test('Assert navigation bar is present', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page.getByRole('navigation')).toBeVisible();
});

test('Assert footer is present', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(await getFooter(page)).toBeVisible();
});
