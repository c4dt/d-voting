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
