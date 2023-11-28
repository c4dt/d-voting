import { test, expect } from '@playwright/test';
import { default as i18n } from 'i18next';
import en from './../../src/language/en.json';
import de from './../../src/language/de.json';
import fr from './../../src/language/fr.json';

export function initI18n() {
  i18n.init({
    resources: { en, fr, de },
    fallbackLng: ['en', 'fr', 'de'],
    debug: true,
  });
}

export async function logIn(page: any) {
  await page.getByRole('button', { name: i18n.t('login') }).dispatchEvent('click');
}

export async function logInNonAdmin (page: any) {
  await logIn(page);
  await page.getByRole('button', { name: i18n.t('Profile') }).dispatchEvent('click');
  await page.getByRole('menuitem', { name: i18n.t('changeId') }).dispatchEvent('click');
  await page.getByPlaceholder(i18n.t('changeIdPlaceholder')).fill('123456');
  await logIn(page);
}

export async function logOut (page: any) {
  await page.getByRole('button', { name: i18n.t('Profile') }).dispatchEvent('click');
  await page.getByRole('menuitem', { name: i18n.t('logout') }).dispatchEvent('click');
  await page.getByRole('button', { name: i18n.t('continue') }).dispatchEvent('click');
}

export async function assertOnlyVisibleToAuthenticated(page: any, role: string, key: string) {
  const element = page.getByRole(role, { name: i18n.t(key) });
  await expect(element).toBeHidden();   // assert is hidden to unauthenticated user
  await logInNonAdmin(page);
  await expect(element).toBeVisible();  // assert is visible to authenticated non-admin user
}

export async function assertOnlyVisibleToAdmin(page: any, role: string, key: string) {
  const element = page.getByRole(role, { name: i18n.t(key) });
  await expect(element).toBeHidden();   // assert is hidden to unauthenticated user
  await logInNonAdmin(page);
  await expect(element).toBeHidden();   // assert is hidden to non-admin user
  await logOut(page);
  await logIn(page);
  await expect(element).toBeVisible();  // assert is visible to admin user
}
