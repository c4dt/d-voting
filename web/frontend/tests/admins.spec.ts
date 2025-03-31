import { assertHasFooter, assertHasNavBar, initI18n, logIn, setUp } from './shared';
import { expect, test } from '@playwright/test';
import { SCIPER_ADMIN, mockProxyList } from './mocks/api';
import { default as i18n } from 'i18next';
import Worker0 from './json/api/proxies/dela-worker-0.json';

initI18n();

test.beforeEach(async ({ page }) => {
  await logIn(page, SCIPER_ADMIN);
  await mockProxyList(page);
  await setUp(page, `/admin`);
});

// main elements

test('Assert navigation bar is present', async ({ page }) => {
  await assertHasNavBar(page);
});

test('Assert footer is present', async ({ page }) => {
  await assertHasFooter(page);
});

// Main content is present
test('Assert pagination for admin and DKG panels are present', async ({ page }) => {
  await expect(page.getByLabel('Pagination')).toHaveCount(2);
  await expect(page.getByRole('button', { name: i18n.t('previous') })).toHaveCount(2);
  await expect(page.getByRole('button', { name: i18n.t('next') })).toHaveCount(2);
});

test('Assert tables are present and have the right amount of rows', async ({ page }) => {
  await expect(
    page.getByRole('table').filter({ has: page.getByText(i18n.t('role')) })
  ).toBeVisible();
  await expect(
    page.getByRole('table').filter({ has: page.getByText(i18n.t('proxy')) })
  ).toBeVisible();

  // Beware: This includes the header row
  await expect(
    page
      .getByRole('table')
      .filter({ has: page.getByText(i18n.t('role')) })
      .getByRole('row')
  ).toHaveCount(3);

  await expect(
    page
      .getByRole('table')
      .filter({ has: page.getByText(i18n.t('proxy')) })
      .getByRole('row')
  ).toHaveCount(5);
});

test('Assert "Add admin" button is working', async ({ page, baseURL }) => {
  const adminToAdd = '111111';
  page.waitForRequest(async (request) => {
    const body = await request.postDataJSON();
    return (
      request.url() === `${baseURL}/api/evoting/auth/addadmin` &&
      request.method() === 'POST' &&
      body.TargetUserID === adminToAdd
    );
  });
  await page.getByRole('button', { name: i18n.t('addUser') }).click();
  // menu should be visible
  const textbox = await page.getByRole('textbox', { name: 'Sciper' });
  await expect(textbox).toBeVisible();
  // add 1 admin
  await textbox.fill(adminToAdd);
  // click on confirmation
  const addButton = await page
    .getByLabel(i18n.t('enterSciper'))
    .getByRole('button', { name: i18n.t('addUser') });
  await addButton.click();
  await expect(addButton).not.toBeVisible();
});

test('Assert "Remove admin" button is working', async ({ page, baseURL }) => {
  const adminToRemove = '123456';
  page.waitForRequest(async (request) => {
    const body = await request.postDataJSON();
    return (
      request.url() === `${baseURL}/api/evoting/auth/removeadmin` &&
      request.method() === 'POST' &&
      body.TargetUserID === adminToRemove
    );
  });
  await page
    .getByRole('row')
    .filter({ has: page.getByText(adminToRemove) })
    .getByText(i18n.t('delete'))
    .click();
  const delButton = page
    .getByLabel(i18n.t('confirmDeleteUserSciper'))
    .getByRole('button', { name: i18n.t('delete') });
  await expect(delButton).toBeVisible();
  await delButton.click();
  await expect(delButton).not.toBeVisible();
});

test('Assert "Add proxy" button is working', async ({ page, baseURL }) => {
  const proxyToAdd = { NodeAddr: 'grpc://dela-worker-4:2000', Proxy: 'http://172.19.44.251:8080' };
  page.waitForRequest(async (request) => {
    const body = await request.postDataJSON();
    return (
      request.url() === `${baseURL}/api/proxies/` &&
      request.method() === 'POST' &&
      body.NodeAddr === proxyToAdd.NodeAddr &&
      body.Proxy === proxyToAdd.Proxy
    );
  });
  await page.getByRole('button', { name: i18n.t('addProxy') }).click();
  await expect(page.locator('#proxy')).toBeVisible();
  await page.locator('#proxy').fill(proxyToAdd.Proxy);
  await page.locator('#node').fill(proxyToAdd.NodeAddr);
  const addButton = page
    .getByLabel(i18n.t('enterNodeProxy'))
    .getByRole('button', { name: i18n.t('add') });
  await expect(addButton).toBeVisible();
  await addButton.click();
  await expect(page.getByLabel(i18n.t('enterNodeProxy'))).not.toBeVisible();
});

test('Assert "Remove proxy" button is working', async ({ page, baseURL }) => {
  page.waitForRequest(async (request) => {
    return (
      request.url() === `${baseURL}/api/proxies/${encodeURIComponent(Worker0.NodeAddr)}` &&
      request.method() === 'DELETE'
    );
  });
  await page
    .getByRole('row')
    .filter({ has: page.getByText(Worker0.Proxy) })
    .getByText(i18n.t('delete'))
    .click();
  const delButton = page
    .getByLabel(i18n.t('confirmDeleteProxy'))
    .getByRole('button', { name: i18n.t('delete') });
  await expect(delButton).toBeVisible();
  await delButton.click();
  await expect(delButton).not.toBeVisible();
});

test('Assert "Edit proxy" button is working', async ({ page, baseURL }) => {
  const proxyToAdd = { NodeAddr: 'grpc://dela-worker-4:2000', Proxy: 'http://172.19.44.248:8080' };
  page.waitForRequest(async (request) => {
    const body = await request.postDataJSON();
    return (
      request.url() === `${baseURL}/api/proxies/${encodeURIComponent(Worker0.NodeAddr)}` &&
      request.method() === 'PUT' &&
      body.NewNode === proxyToAdd.NodeAddr &&
      body.Proxy === proxyToAdd.Proxy
    );
  });
  await expect(
    page.getByRole('row').filter({ has: page.getByText(Worker0.NodeAddr) })
  ).toBeVisible();
  // Would be better to use the same "locators" that the user would use.
  // But there are 2 different buttons one for mobile and the other for
  // desktop that have the same description. Using a class tag is the best way to distinguish them
  await page
    .getByRole('row')
    .filter({ has: page.getByText(Worker0.Proxy) })
    .locator('.test-large-edit')
    .click();
  await expect(page.getByText(i18n.t('editProxy'))).toBeVisible();
  await page.locator('#proxy').fill(proxyToAdd.Proxy);
  await page.locator('#node').fill(proxyToAdd.NodeAddr);
  const editButton = page
    .getByLabel(i18n.t('editProxy'))
    .getByRole('button', { name: i18n.t('save') });
  await editButton.click();
  await expect(editButton).not.toBeVisible();
});
