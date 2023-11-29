import { test, expect } from '@playwright/test';
import { default as i18n } from 'i18next';
import { initI18n } from './utils';

initI18n();

export async function getFooter(page) {
  return await page.locator('//*[@id="root"]/div[1]/div[4]/div[1]/footer');
}
