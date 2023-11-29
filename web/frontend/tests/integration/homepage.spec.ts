import { test, expect } from '@playwright/test';
import { assertNavigationPresent, assertFooterPresent } from './utils';

test('Assert homepage has correct title', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page).toHaveTitle(/D-Voting/);
});

test('Assert navigation bar is present', async({ page }) => assertNavigationPresent(page));

test('Assert footer is present', async({ page }) => assertFooterPresent(page));
