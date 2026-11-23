#!/usr/bin/env node
// Exercises the Community rules against the local emulator with the client
// SDK: feed queries, aggregates, reactions, comments, replies and deletes,
// plus forgery attempts that must be denied. Run after `seed.mjs seed
// --emulator` (it reads the sample readers' posts).
//
//   node check-community.mjs --emulator
//
// Creates two throwaway readers (@qa_alice, @qa_bob) and leaves @qa_alice
// with one public post so `seed.mjs seed --emulator --friend qa_alice`
// has something to react to. Exits non-zero if any check fails.

import { initializeApp } from 'firebase/app';
import {
  connectAuthEmulator,
  createUserWithEmailAndPassword,
  getAuth,
  signInWithEmailAndPassword,
  signOut,
} from 'firebase/auth';
import {
  average,
  collection,
  collectionGroup,
  connectFirestoreEmulator,
  count,
  deleteDoc,
  doc,
  getAggregateFromServer,
  getCountFromServer,
  getDoc,
  getDocs,
  getFirestore,
  increment,
  limit,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  setDoc,
  startAfter,
  updateDoc,
  where,
  writeBatch,
} from 'firebase/firestore';

import { BOOKS } from './data.mjs';

if (!process.argv.includes('--emulator')) {
  console.error('Only runs against the emulator: node check-community.mjs --emulator');
  process.exit(1);
}

const app = initializeApp({ apiKey: 'demo', projectId: 'demo-bookmunity' });
const auth = getAuth(app);
const db = getFirestore(app);
connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
connectFirestoreEmulator(db, '127.0.0.1', 8080);

const PASSWORD = process.env.SEED_PASSWORD ?? 'bookmunity-seed';
const results = [];

async function signIn(username, { create = false } = {}) {
  await signOut(auth);
  const email = `${username}@seed.bookmunity.app`;
  try {
    return (await signInWithEmailAndPassword(auth, email, PASSWORD)).user.uid;
  } catch (error) {
    if (!create) throw error;
    return (await createUserWithEmailAndPassword(auth, email, PASSWORD)).user.uid;
  }
}

async function ensureProfile(uid, username, displayName) {
  if ((await getDoc(doc(db, 'profiles', uid))).exists()) return;
  const batch = writeBatch(db);
  batch.set(doc(db, 'usernames', username), { uid });
  batch.set(doc(db, 'profiles', uid), {
    uid, username, usernameLower: username, displayName,
    booksFinished: 0, currentStreak: 0, longestStreak: 0, badgeCount: 0,
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  });
  await batch.commit();
}

async function allowed(label, action) {
  try {
    const detail = await action();
    results.push([true, 'allow', label, detail ?? '']);
  } catch (error) {
    results.push([false, 'allow', label, `${error.code ?? ''} ${error.message.split('\n')[0]}`]);
  }
}

async function denied(label, action) {
  try {
    await action();
    results.push([false, 'deny ', label, 'was allowed']);
  } catch (error) {
    const ok = error.code === 'permission-denied';
    results.push([ok, 'deny ', label, ok ? '' : `${error.code} ${error.message}`]);
  }
}

const expect = (condition, message) => {
  if (!condition) throw new Error(message);
  return message;
};

const zero = { like: 0, love: 0, haha: 0, wow: 0, sad: 0 };
const book = BOOKS.pride;
const post = (uid, profile, extra = {}) => ({
  authorUid: uid,
  authorUsername: profile.username,
  authorDisplayName: profile.displayName,
  type: 'quote',
  visibility: 'public',
  bookKey: book.key,
  title: book.title,
  author: book.author,
  coverUrl: '',
  rating: 0,
  text: 'A note',
  quote: 'It is a truth universally acknowledged…',
  chapter: 'Chapter 1',
  progress: 0,
  badgeId: '',
  badgeTitle: '',
  reactions: zero,
  commentCount: 0,
  commentOpId: '',
  createdAt: serverTimestamp(),
  updatedAt: serverTimestamp(),
  ...extra,
});

// Mirrors CommunityRepository.setReaction.
const react = (postId, uid, profile, type) =>
  runTransaction(db, async (transaction) => {
    const ref = doc(db, 'posts', postId, 'reactions', uid);
    const current = await transaction.get(ref);
    const before = current.exists() ? current.data().type : null;
    const changes = {};
    if (before) changes[`reactions.${before}`] = increment(-1);
    if (type) changes[`reactions.${type}`] = increment(1);
    transaction.update(doc(db, 'posts', postId), changes);
    if (type) {
      transaction.set(ref, { uid, type, username: profile.username, displayName: profile.displayName, updatedAt: serverTimestamp() });
    } else {
      transaction.delete(ref);
    }
  });

// Mirrors CommunityRepository.addComment / _deleteOne.
const comment = async (postId, uid, profile, text, parentId = '') => {
  const ref = doc(collection(db, 'posts', postId, 'comments'));
  const batch = writeBatch(db);
  batch.set(ref, { authorUid: uid, authorUsername: profile.username, authorDisplayName: profile.displayName, text, parentId, createdAt: serverTimestamp() });
  batch.update(doc(db, 'posts', postId), { commentCount: increment(1), commentOpId: ref.id });
  await batch.commit();
  return ref.id;
};
const uncomment = (postId, commentId) => {
  const batch = writeBatch(db);
  batch.delete(doc(db, 'posts', postId, 'comments', commentId));
  batch.update(doc(db, 'posts', postId), { commentCount: increment(-1), commentOpId: commentId });
  return batch.commit();
};
const postData = async (postId) => (await getDoc(doc(db, 'posts', postId))).data();

// ------------------------------------------------------------- setup

const alice = { username: 'qa_alice', displayName: 'QA Alice' };
const bob = { username: 'qa_bob', displayName: 'QA Bob' };
const bobUid = await signIn(bob.username, { create: true });
await ensureProfile(bobUid, bob.username, bob.displayName);
const aliceUid = await signIn(alice.username, { create: true });
await ensureProfile(aliceUid, alice.username, alice.displayName);
const ayeshaUid = (await getDoc(doc(db, 'usernames', 'ayesha_reads'))).data()?.uid;
const zainabUid = (await getDoc(doc(db, 'usernames', 'zainab_lit'))).data()?.uid;
if (!ayeshaUid || !zainabUid) {
  console.error('Run `node seed.mjs seed --emulator` first.');
  process.exit(1);
}

// -------------------------------------------------------------- feeds
// Bob is friends with nobody.
await signIn(bob.username);

await allowed('Everyone feed: public posts, newest first, 2 pages', async () => {
  const first = await getDocs(query(collection(db, 'posts'), where('visibility', '==', 'public'), orderBy('createdAt', 'desc'), limit(10)));
  const second = await getDocs(query(collection(db, 'posts'), where('visibility', '==', 'public'), orderBy('createdAt', 'desc'), startAfter(first.docs.at(-1)), limit(10)));
  const ids = new Set([...first.docs, ...second.docs].map((d) => d.id));
  expect(first.size === 10 && second.size === 10 && ids.size === 20, `${first.size} + ${second.size} posts, no overlap`);
  return `${first.size} + ${second.size} posts, no overlap`;
});

await denied('Everyone feed without the visibility filter (could include friends-only)', () =>
  getDocs(query(collection(db, 'posts'), orderBy('createdAt', 'desc'), limit(10))));

await denied('Non-friend lists Zainab’s posts without visibility filter', () =>
  getDocs(query(collection(db, 'posts'), where('authorUid', '==', zainabUid))));

await allowed('Non-friend lists Zainab’s public posts', async () => {
  const result = await getDocs(query(collection(db, 'posts'), where('authorUid', '==', zainabUid), where('visibility', '==', 'public'), orderBy('createdAt', 'desc')));
  return `${result.size} posts`;
});

await denied('Non-friend reads Zainab’s friends-only quote', () =>
  getDoc(doc(db, 'posts', `${zainabUid}_seedquote_alice`)));

await signIn('ayesha_reads');
const ayeshaFriends = (await getDocs(collection(db, 'users', ayeshaUid, 'friends'))).docs.map((d) => d.id);
await allowed('Friends feed for Ayesha: authorUid in [me + friends]', async () => {
  const result = await getDocs(query(collection(db, 'posts'), where('authorUid', 'in', [ayeshaUid, ...ayeshaFriends]), orderBy('createdAt', 'desc'), limit(15)));
  return `${result.size} posts from ${ayeshaFriends.length} friends + self`;
});
await denied('Friends feed that sneaks in a non-friend (Zainab)', () =>
  getDocs(query(collection(db, 'posts'), where('authorUid', 'in', [ayeshaUid, zainabUid]), orderBy('createdAt', 'desc'))));

await signIn('mariam_reads');
await allowed('Friend (Mariam) reads Zainab’s friends-only quote', async () => {
  const snapshot = await getDoc(doc(db, 'posts', `${zainabUid}_seedquote_alice`));
  return expect(snapshot.data()?.visibility === 'friends', 'friends-only post readable');
});

await signIn(alice.username);
await allowed('Aggregates: book rating, reader ratings, friend count, shelf', async () => {
  const rating = await getAggregateFromServer(collection(db, 'books', book.key, 'reviews'), { n: count(), avg: average('rating') });
  const ratings = await getAggregateFromServer(query(collectionGroup(db, 'reviews'), where('uid', '==', ayeshaUid)), { n: count(), avg: average('rating') });
  const friends = await getCountFromServer(collection(db, 'users', ayeshaUid, 'friends'));
  const shelf = await getDocs(collection(db, 'users', ayeshaUid, 'library'));
  const badges = await getDocs(collection(db, 'users', ayeshaUid, 'badges'));
  return `${book.title}: ${rating.data().avg.toFixed(2)} from ${rating.data().n}; Ayesha: ${ratings.data().n} ratings, ` +
    `${friends.data().count} friends, ${shelf.size} shelf books, ${badges.size} badges`;
});

// ------------------------------------------------------- legit writes

const keptId = `${aliceUid}_finished_${book.key}`;
await allowed('Alice creates a "finished" post (kept for the --friend seed)', async () => {
  if (!(await getDoc(doc(db, 'posts', keptId))).exists()) {
    await setDoc(doc(db, 'posts', keptId), post(aliceUid, alice, { type: 'finished', text: '', quote: '', chapter: '' }));
  }
});

const quoteId = `${aliceUid}_qa${Date.now()}`;
await allowed('Alice shares a quote', () => setDoc(doc(db, 'posts', quoteId), post(aliceUid, alice)));
await allowed('Alice edits her quote note and visibility', () =>
  updateDoc(doc(db, 'posts', quoteId), { text: 'Edited note', visibility: 'friends', authorDisplayName: alice.displayName, updatedAt: serverTimestamp() }));
await allowed('Alice makes it public again', () =>
  updateDoc(doc(db, 'posts', quoteId), { visibility: 'public', updatedAt: serverTimestamp() }));

await signIn(bob.username);
await allowed('Bob reacts like', async () => {
  await react(quoteId, bobUid, bob, 'like');
  return expect((await postData(quoteId)).reactions.like === 1, 'like = 1');
});
await allowed('Bob changes his reaction to love', async () => {
  await react(quoteId, bobUid, bob, 'love');
  const { reactions } = await postData(quoteId);
  return expect(reactions.like === 0 && reactions.love === 1, 'like = 0, love = 1');
});
let bobComment;
await allowed('Bob comments', async () => {
  bobComment = await comment(quoteId, bobUid, bob, 'Lovely line!');
  return expect((await postData(quoteId)).commentCount === 1, 'commentCount = 1');
});

await signIn(alice.username);
let aliceReply;
await allowed('Alice replies to Bob', async () => {
  aliceReply = await comment(quoteId, aliceUid, alice, 'Thank you!', bobComment);
  return expect((await postData(quoteId)).commentCount === 2, 'commentCount = 2');
});
await denied('Alice replies to a reply (only one level)', () => comment(quoteId, aliceUid, alice, 'Nested', aliceReply));

// ------------------------------------------------------------ forgery

await signIn(bob.username);
await denied('Bob creates a post as Alice (fake authorUid)', () =>
  setDoc(doc(db, 'posts', `${aliceUid}_fake`), post(aliceUid, alice)));
await denied('Bob creates a post with someone else’s id prefix', () =>
  setDoc(doc(db, 'posts', `${aliceUid}_review_x`), post(bobUid, bob)));
await denied('Bob creates a post with a fake display name', () =>
  setDoc(doc(db, 'posts', `${bobUid}_fake1`), post(bobUid, { ...bob, displayName: 'Jane Austen' })));
await denied('Bob creates a post with 500 likes already', () =>
  setDoc(doc(db, 'posts', `${bobUid}_fake2`), post(bobUid, bob, { reactions: { ...zero, like: 500 } })));
await denied('Bob creates a post with commentCount 10', () =>
  setDoc(doc(db, 'posts', `${bobUid}_fake3`), post(bobUid, bob, { commentCount: 10 })));
await denied('Bob creates a review without a rating', () =>
  setDoc(doc(db, 'posts', `${bobUid}_fake4`), post(bobUid, bob, { type: 'review', quote: '', rating: 0 })));
await denied('Bob edits Alice’s post text', () =>
  updateDoc(doc(db, 'posts', quoteId), { text: 'hacked', updatedAt: serverTimestamp() }));
await denied('Bob deletes Alice’s post', () => deleteDoc(doc(db, 'posts', quoteId)));
await denied('Bob inflates likes without a reaction', () =>
  updateDoc(doc(db, 'posts', quoteId), { 'reactions.like': increment(10) }));
await denied('Bob bumps likes by one without a reaction doc', () =>
  updateDoc(doc(db, 'posts', quoteId), { 'reactions.wow': increment(1) }));
await denied('Bob reacts as Alice (reaction doc with her uid)', () => react(quoteId, aliceUid, alice, 'wow'));
await denied('Bob writes a reaction without updating the counter', () =>
  setDoc(doc(db, 'posts', quoteId, 'reactions', bobUid), { uid: bobUid, type: 'haha', username: bob.username, displayName: bob.displayName, updatedAt: serverTimestamp() }));
await denied('Bob reacts with +2 on the counter', () =>
  runTransaction(db, async (transaction) => {
    transaction.update(doc(db, 'posts', quoteId), { 'reactions.love': increment(-1), 'reactions.haha': increment(2) });
    transaction.set(doc(db, 'posts', quoteId, 'reactions', bobUid), { uid: bobUid, type: 'haha', username: bob.username, displayName: bob.displayName, updatedAt: serverTimestamp() });
  }));
await denied('Bob bumps commentCount without a comment', () =>
  updateDoc(doc(db, 'posts', quoteId), { commentCount: increment(1), commentOpId: 'nothing' }));
await denied('Bob adds a comment but counts it 5 times', () => {
  const ref = doc(collection(db, 'posts', quoteId, 'comments'));
  const batch = writeBatch(db);
  batch.set(ref, { authorUid: bobUid, authorUsername: bob.username, authorDisplayName: bob.displayName, text: 'x', parentId: '', createdAt: serverTimestamp() });
  batch.update(doc(db, 'posts', quoteId), { commentCount: increment(5), commentOpId: ref.id });
  return batch.commit();
});
await denied('Bob comments without counting it', () =>
  setDoc(doc(collection(db, 'posts', quoteId, 'comments')), { authorUid: bobUid, authorUsername: bob.username, authorDisplayName: bob.displayName, text: 'x', parentId: '', createdAt: serverTimestamp() }));
await denied('Bob comments as Alice', () => comment(quoteId, aliceUid, alice, 'I am Alice'));
await denied('Bob edits his comment (comments are immutable)', () =>
  updateDoc(doc(db, 'posts', quoteId, 'comments', bobComment), { text: 'edited' }));

await signIn('ayesha_reads');
await denied('Ayesha deletes Alice’s reply (not hers, not her post or thread)', () =>
  uncomment(quoteId, aliceReply));
await denied('Ayesha deletes Bob’s comment', () => uncomment(quoteId, bobComment));
await denied('Ayesha (not a friend) comments on Zainab’s friends-only quote', () =>
  comment(`${zainabUid}_seedquote_alice`, ayeshaUid, { username: 'ayesha_reads', displayName: 'Ayesha Khan' }, 'hi'));

// ----------------------------------------------------- legit deletes

await signIn(bob.username);
await allowed('Bob deletes Alice’s reply in his own thread', async () => {
  await uncomment(quoteId, aliceReply);
  return expect((await postData(quoteId)).commentCount === 1, 'commentCount = 1');
});
await signIn(alice.username);
await allowed('Alice (post author) deletes Bob’s comment', async () => {
  await uncomment(quoteId, bobComment);
  return expect((await postData(quoteId)).commentCount === 0, 'commentCount = 0');
});
await signIn(bob.username);
await allowed('Bob removes his reaction', async () => {
  await react(quoteId, bobUid, bob, null);
  const { reactions } = await postData(quoteId);
  return expect(Object.values(reactions).every((n) => n === 0), 'all reactions 0');
});
let ownComment;
await allowed('Bob comments again and deletes his own comment', async () => {
  ownComment = await comment(quoteId, bobUid, bob, 'Again');
  await uncomment(quoteId, ownComment);
  return expect((await postData(quoteId)).commentCount === 0, 'commentCount = 0');
});
await react(quoteId, bobUid, bob, 'wow');
const leftover = await comment(quoteId, bobUid, bob, 'Left behind');
await signIn(alice.username);
await allowed('Alice deletes her post with its comments and reactions in one batch', async () => {
  const children = [
    ...(await getDocs(collection(db, 'posts', quoteId, 'comments'))).docs,
    ...(await getDocs(collection(db, 'posts', quoteId, 'reactions'))).docs,
  ];
  const batch = writeBatch(db);
  batch.delete(doc(db, 'posts', quoteId));
  for (const child of children) batch.delete(child.ref);
  await batch.commit();
  return `${children.length} children removed`;
});
await signIn(bob.username);
await allowed('Deleted post reads as missing', async () =>
  expect(!(await getDoc(doc(db, 'posts', quoteId))).exists(), 'post gone'));
void leftover;

// ------------------------------------------------- counter integrity

await signIn('zainab_lit');
await allowed('Counters equal the reaction and comment docs on every readable post', async () => {
  const zainabFriends = (await getDocs(collection(db, 'users', zainabUid, 'friends'))).docs.map((d) => d.id);
  const visible = new Map();
  for (const snapshot of [
    await getDocs(query(collection(db, 'posts'), where('visibility', '==', 'public'))),
    await getDocs(query(collection(db, 'posts'), where('authorUid', 'in', [zainabUid, ...zainabFriends]))),
  ]) {
    for (const d of snapshot.docs) visible.set(d.id, d.data());
  }
  for (const [id, data] of visible) {
    const reactions = (await getDocs(collection(db, 'posts', id, 'reactions'))).docs.map((d) => d.data().type);
    const comments = await getCountFromServer(collection(db, 'posts', id, 'comments'));
    for (const type of Object.keys(zero)) {
      const actual = reactions.filter((t) => t === type).length;
      expect(data.reactions[type] === actual, `${id}: ${type} ${data.reactions[type]} != ${actual}`);
    }
    expect(data.commentCount === comments.data().count, `${id}: commentCount ${data.commentCount} != ${comments.data().count}`);
  }
  return `${visible.size} posts checked`;
});

// ------------------------------------------------------------- report

await signOut(auth);
let failures = 0;
for (const [ok, kind, label, detail] of results) {
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${kind}  ${label}${detail ? `  (${detail})` : ''}`);
}
console.log(`\n${results.length - failures}/${results.length} checks passed.`);
process.exit(failures ? 1 : 0);
