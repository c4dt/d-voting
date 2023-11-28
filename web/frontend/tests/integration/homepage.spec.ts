import { test, expect } from '@playwright/test';
import { default as i18n } from 'i18next';
import { initI18n, logIn, logInNonAdmin, logOut } from './utils';

initI18n();

// unauthenticated view

test('Assert homepage has correct title', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page).toHaveTitle(/D-Voting/);
});

test('Assert login button sets cookie', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  const login = page.getByRole('button', { name: i18n.t('login') });
  await login.click();
  const cookies = await page.context().cookies();
  expect(cookies.find(cookie => cookie.name == 'connect.sid')).toBeTruthy();
});


// authenticated non-admin view

async function assertOnlyVisibleToAuthenticated(page: any, role: string, key: string) {
  const element = page.getByRole(role, { name: i18n.t(key) });
  await expect(element).toBeHidden();   // assert is hidden to unauthenticated user
  await logInNonAdmin(page);
  await expect(element).toBeVisible();  // assert is visible to authenticated non-admin user
}

test('Assert profile button is visible to any user', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await assertOnlyVisibleToAuthenticated(page, 'button', 'Profile');
});


// assert admin view

async function assertOnlyVisibleToAdmin(page: any, role: string, key: string) {
  const element = page.getByRole(role, { name: i18n.t(key) });
  await expect(element).toBeHidden();   // assert is hidden to unauthenticated user
  await logInNonAdmin(page);
  await expect(element).toBeHidden();   // assert is hidden to non-admin user
  await logOut(page);
  await logIn(page);
  await expect(element).toBeVisible();  // assert is visible to admin user
}

test('Assert form creation button is only visible to admin', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await assertOnlyVisibleToAdmin(page, 'link', 'navBarCreateForm');
});

test('Assert administration button is only visible to admin', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await assertOnlyVisibleToAdmin(page, 'link', 'navBarAdmin');
});
