import { test, expect } from '@playwright/test';
import { default as i18n } from 'i18next';
import { initI18n, getFooter } from './utils';

initI18n();

test('Assert footer content is present', async ({ page }) => {
  await page.goto(process.env.FRONT_END_URL);
  await expect(page.getByText(i18n.t('© 2022 DEDIS LAB -')).first()).toBeVisible();
  await expect(
    page.getByRole('link', { name: 'https://github.com/c4dt/d-voting' }).first()
  ).toBeVisible();
  await expect(
    page.getByText(`version:${process.env.REACT_APP_VERSION || 'unknown'} - build ${process.env.REACT_APP_BUILD || 'unknown'} - on ${process.env.REAC_APP_BUILD_TIME || 'unknown'}`)
  ).toBeVisible()
});
