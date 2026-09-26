/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { describe, it, expect } from '@ohos/hypium';
import { ItemType } from '../main/ets/domain/model/ItemType';
import { EncString } from '../main/ets/domain/model/EncString';
import { Attachment } from '../main/ets/domain/model/Attachment';
import { Cipher, EncField, FieldType, LoginDetails } from '../main/ets/domain/model/Cipher';
import { Folder } from '../main/ets/domain/model/Folder';
import { KdfType, KdfParams, VaultContext } from '../main/ets/domain/model/VaultContext';
import { Session } from '../main/ets/domain/model/Session';
import { OutboxOp } from '../main/ets/domain/model/OutboxOp';
import { SyncState } from '../main/ets/domain/model/SyncState';
import { EncStringCodec } from '../main/ets/domain/crypto/EncStringCodec';
import { SecureNotePayload } from '../main/ets/domain/protocol/Types';

export default function modelTest() {
  describe('DomainModel', () => {

    it('item_type_wire_values_match_bitwarden', 0, () => {
      expect(ItemType.Login).assertEqual(1);
      expect(ItemType.SecureNote).assertEqual(2);
      expect(ItemType.Card).assertEqual(3);
      expect(ItemType.Identity).assertEqual(4);
    });

    it('field_type_wire_values_match_bitwarden', 0, () => {
      expect(FieldType.Text).assertEqual(0);
      expect(FieldType.Hidden).assertEqual(1);
      expect(FieldType.Boolean).assertEqual(2);
      expect(FieldType.Linked).assertEqual(3);
    });

    it('kdf_type_wire_values_match_bitwarden', 0, () => {
      expect(KdfType.Pbkdf2).assertEqual(0);
      expect(KdfType.Argon2id).assertEqual(1);
    });

    it('boolean_field_defaults_to_null_value', 0, () => {
      const name = new EncString('AesCbc256_HmacSha256_B64', 'iv==', 'ct==', 'mac==');
      const field = new EncField(FieldType.Boolean, name);
      expect(field.value).assertNull();
    });

    it('linked_field_preserves_its_reference_id', 0, () => {
      const name = new EncString('AesCbc256_HmacSha256_B64', 'iv==', 'ct==', 'mac==');
      const field = new EncField(FieldType.Linked, name, null, 101);
      expect(field.linkedId).assertEqual(101);
      expect(field.value).assertNull();
    });

    it('secure_note_payload_construction', 0, () => {
      const payload = new SecureNotePayload();
      expect(payload.type).assertEqual(0);
      const custom = new SecureNotePayload(1);
      expect(custom.type).assertEqual(1);
    });

    it('login_cipher_construction', 0, () => {
      const username = new EncString('AesCbc256_HmacSha256_B64', 'ivA==', 'ctA==', 'macA==');
      const password = new EncString('AesCbc256_HmacSha256_B64', 'ivB==', 'ctB==', 'macB==');
      const totp = new EncString('AesCbc256_HmacSha256_B64', 'ivC==', 'ctC==', 'macC==');
      const login = new LoginDetails(username, password, totp, []);
      const cipher = new Cipher('c-id', 'v-id', ItemType.Login, null, 1000, true, 'folder-1',
        null, [], login);

      expect(cipher.id).assertEqual('c-id');
      expect(cipher.vaultId).assertEqual('v-id');
      expect(cipher.type).assertEqual(ItemType.Login);
      expect(cipher.organizationId).assertNull();
      expect(cipher.favorite).assertTrue();
      expect(cipher.folderId).assertEqual('folder-1');
      expect(cipher.deletedDate).assertNull();
      const storedLogin = cipher.login as LoginDetails;
      expect(storedLogin.username).assertEqual(username);
      expect(storedLogin.password).assertEqual(password);
      expect(storedLogin.totp).assertEqual(totp);
      expect(cipher.attachments.length).assertEqual(0);
    });

    it('org_cipher_carries_organization_id_for_filtering', 0, () => {
      const cipher = new Cipher('c-id', 'v-id', ItemType.Login, 'org-1', 1000);
      expect(cipher.organizationId).assertEqual('org-1');
    });

    it('attachment_construction', 0, () => {
      const key = new EncString('AesCbc256_HmacSha256_B64', 'iv==', 'ct==', 'mac==');
      const attachment = new Attachment('a-id', 'c-id', '入职材料.pdf', 1258291, key, 'https://vault.example.com/att/a-id');
      expect(attachment.cipherId).assertEqual('c-id');
      expect(attachment.size).assertEqual(1258291);
      expect(attachment.key).assertEqual(key);
    });

    it('folder_construction', 0, () => {
      const name = new EncString('AesCbc128_HmacSha256_B64', 'iv==', 'ct==', 'mac==');
      const folder = new Folder('f-id', 'v-id', name, 2000);
      expect(folder.name).assertEqual(name);
      expect(folder.revisionDate).assertEqual(2000);
    });

    it('vault_context_with_argon2_params', 0, () => {
      const kdf = new KdfParams(KdfType.Argon2id, 3, 65536, 4);
      const context = new VaultContext('v-id', 'https://vaultwarden.example.com', 'user@example.com', 'acct-1', kdf);
      expect(context.kdf.type).assertEqual(KdfType.Argon2id);
      expect(context.kdf.iterations).assertEqual(3);
      expect(context.kdf.memory).assertEqual(65536);
      expect(context.kdf.parallelism).assertEqual(4);
    });

    it('vault_context_with_pbkdf2_params', 0, () => {
      const kdf = new KdfParams(KdfType.Pbkdf2, 600000);
      expect(kdf.memory).assertNull();
      expect(kdf.parallelism).assertNull();
    });

    it('session_construction', 0, () => {
      const session = new Session('access-token', 'refresh-token', 1757068800000);
      expect(session.accessToken).assertEqual('access-token');
      expect(session.refreshToken).assertEqual('refresh-token');
      expect(session.expiresAt).assertEqual(1757068800000);
    });

    it('outbox_op_construction', 0, () => {
      const op = new OutboxOp(1, 'c-id', 'save', '{"id":"c-id"}', 3000);
      expect(op.seq).assertEqual(1);
      expect(op.op).assertEqual('save');
      expect(op.payload).assertEqual('{"id":"c-id"}');
      const softDelete = new OutboxOp(2, 'c-id', 'softDelete', null, 3001);
      expect(softDelete.op).assertEqual('softDelete');
      expect(softDelete.payload).assertNull();
    });

    it('sync_state_construction', 0, () => {
      const state = new SyncState('v-id', 4000);
      expect(state.vaultId).assertEqual('v-id');
      expect(state.lastSyncAt).assertEqual(4000);
    });

    it('model_and_codec_roundtrip_together', 0, () => {
      const mac = new EncString('AesCbc256_HmacSha256_B64', 'iv==', 'ct==', 'mac==');
      const serialized = EncStringCodec.encode(mac);
      expect(serialized).assertEqual('2.iv==|ct==|mac==');
    });
  });
}
