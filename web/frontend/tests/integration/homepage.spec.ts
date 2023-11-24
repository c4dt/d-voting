import { test, expect } from '@playwright/test';
import { default as i18n } from 'i18next';
import en from './../../src/language/en.json';
import de from './../../src/language/de.json';
import fr from './../../src/language/fr.json';

const resources = { de, en, fr };

i18n.init({
  resources,
  fallbackLng: ['en', 'fr', 'de'],
  debug: true,
});

test('Assert homepage title', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page).toHaveTitle(/D-Voting/);
});

test('Assert login button', async({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  const login = page.getByRole('button', { name: i18n.t('login') });
  await expect(login).toBeVisible();
  await login.click();
  const cookies = await page.context().cookies();
  expect(cookies.find(cookie => cookie.name == 'connect.sid')).toBeTruthy();
});
