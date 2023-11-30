import { test, expect } from '@playwright/test';
import { default as i18n } from 'i18next';
import {
  initI18n,
  logIn,
  logInNonAdmin,
  logOut,
  assertOnlyVisibleToAuthenticated,
  assertOnlyVisibleToAdmin,
} from './utils';

initI18n();

// unauthenticated view

test('Assert about button is present', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page.getByRole('link', { name: i18n.t('navBarAbout') })).toBeVisible();
});

test('Assert link to form list is present', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page.getByRole('link', { name: i18n.t('navBarStatus') })).toBeVisible();
});

test('Assert link to homepage is present', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  const img = await page.getByAltText(i18n.t('Workflow')).all();
  expect(img.some((e) => e.isVisible())).toBeTruthy;
});

test('Assert language button sets language', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await page.getByRole('button', { name: i18n.t('Language') }).click();
  await ['en', 'fr', 'de'].forEach((lng) => {
    expect(page.getByRole('menuitem', { name: i18n.t(lng) })).toBeVisible();
  });
  let currentLng: string = i18n.language;
  for (let lng of ['en', 'fr', 'de']) {
    await page.getByRole('menuitem', { name: i18n.t(lng, { lng: currentLng }) }).click();
    currentLng = lng;
    await page.getByRole('button', { name: i18n.t('Language', {lng: currentLng }) }).click();
  }
});

test('Assert login button sets cookie', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  const login = page.getByRole('button', { name: i18n.t('login') });
  await login.click();
  const cookies = await page.context().cookies();
  expect(cookies.find(cookie => cookie.name == 'connect.sid')).toBeTruthy();
});


// authenticated non-admin view

test('Assert profile button is visible to any user', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await assertOnlyVisibleToAuthenticated(page, 'button', 'Profile');
});


// assert admin view

test('Assert form creation button is only visible to admin', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await assertOnlyVisibleToAdmin(page, 'link', 'navBarCreateForm');
});

test('Assert administration button is only visible to admin', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await assertOnlyVisibleToAdmin(page, 'link', 'navBarAdmin');
});
