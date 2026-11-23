#!/usr/bin/env node
// Seeds sample readers into Bookmunity's Firestore using the normal client
// SDK, so every write goes through firestore.rules exactly like the app's.
//
//   node seed.mjs seed   [--friend <username>] [--emulator]
//   node seed.mjs accept --friend <username>   [--emulator]
//
// Environment:
//   SEED_PASSWORD                  password for all sample accounts
//                                  (default "bookmunity-seed")
//   TESTER_EMAIL, TESTER_PASSWORD  your own account; with --friend this
//                                  makes the sample readers your friends
//                                  right away instead of just requesting.
//
// Safe to re-run: existing accounts, profiles, friendships, posts,
// reactions and comments are reused (never duplicated); profiles, reviews,
// post texts, shelves and badges are refreshed.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { initializeApp } from 'firebase/app';
import {
  connectAuthEmulator,
  createUserWithEmailAndPassword,
  getAuth,
  signInWithEmailAndPassword,
  signOut,
} from 'firebase/auth';
import {
  collection,
  connectFirestoreEmulator,
  doc,
  getDoc,
  getDocs,
  getFirestore,
  increment,
  limit,
  query,
  runTransaction,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
  where,
  writeBatch,
} from 'firebase/firestore';

import {
  BADGES,
  BOOKS,
  COMMENTS,
  coverUrl,
  FRIENDSHIPS,
  sourceUrl,
  TESTER_FRIENDS,
  TESTER_MENTIONS,
  TESTER_POST_COMMENTS,
  TESTER_REQUESTS,
  USERS,
} from './data.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const command = args[0] ?? 'seed';
const flag = (name) => {
  const index = args.indexOf(`--${name}`);
  return index === -1 ? undefined : args[index + 1];
};
const useEmulator = args.includes('--emulator');
const friendUsername = flag('friend');
const password = process.env.SEED_PASSWORD ?? 'bookmunity-seed';

// --------------------------------------------------------------- config

function webConfig() {
  const source = readFileSync(join(here, '../../lib/firebase_options.dart'), 'utf8');
  const block = source.slice(source.indexOf('FirebaseOptions web'));
  const field = (name) => block.match(new RegExp(`${name}: '([^']+)'`))?.[1];
  return {
    apiKey: field('apiKey'),
    authDomain: field('authDomain'),
    projectId: useEmulator ? `demo-${field('projectId')}` : field('projectId'),
    appId: field('appId'),
  };
}

const app = initializeApp(webConfig());
const auth = getAuth(app);
const db = getFirestore(app);
if (useEmulator) {
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
  connectFirestoreEmulator(db, '127.0.0.1', 8080);
}

const emailFor = (username) => `${username}@seed.bookmunity.app`;
const log = (...parts) => console.log(...parts);

// -------------------------------------------------------------- helpers

async function signInAs(email, pass, { create = false } = {}) {
  signedInAs = null;
  await signOut(auth);
  try {
    return (await signInWithEmailAndPassword(auth, email, pass)).user;
  } catch (error) {
    const missing = ['auth/user-not-found', 'auth/invalid-credential', 'auth/invalid-login-credentials'];
    if (!create || !missing.includes(error.code)) throw error;
    return (await createUserWithEmailAndPassword(auth, email, pass)).user;
  }
}

async function profileOf(uid) {
  const snapshot = await getDoc(doc(db, 'profiles', uid));
  return snapshot.exists() ? snapshot.data() : null;
}

async function uidForUsername(username) {
  const snapshot = await getDoc(doc(db, 'usernames', username.toLowerCase()));
  return snapshot.exists() ? snapshot.data().uid : null;
}

// Mirrors SocialRepository.createProfile.
async function ensureProfile(uid, user) {
  const [booksFinished, currentStreak, longestStreak, badgeCount] = user.stats;
  const stats = { booksFinished, currentStreak, longestStreak, badgeCount };
  const existing = await profileOf(uid);
  if (existing) {
    await updateDoc(doc(db, 'profiles', uid), {
      displayName: user.displayName,
      bio: user.bio,
      ...stats,
      updatedAt: serverTimestamp(),
    });
    return 'updated';
  }
  const lower = user.username.toLowerCase();
  await runTransaction(db, async (transaction) => {
    const claimed = await transaction.get(doc(db, 'usernames', lower));
    if (claimed.exists()) throw new Error(`username ${user.username} is taken by someone else`);
    transaction.set(doc(db, 'usernames', lower), { uid });
    transaction.set(doc(db, 'profiles', uid), {
      uid,
      username: user.username,
      usernameLower: lower,
      displayName: user.displayName,
      bio: user.bio,
      hasPhoto: false,
      ...stats,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
  });
  return 'created';
}

// Mirrors SocialRepository.saveReview.
async function saveReview(uid, user, [bookId, rating, text]) {
  const book = BOOKS[bookId];
  const ref = doc(db, 'books', book.key, 'reviews', uid);
  const existing = await getDoc(ref);
  await setDoc(ref, {
    uid,
    username: user.username,
    displayName: user.displayName,
    rating,
    text,
    title: book.title,
    author: book.author,
    createdAt: existing.exists() ? existing.data().createdAt : serverTimestamp(),
    updatedAt: serverTimestamp(),
  });
}

// ------------------------------------------------------------ community

const daysAgo = (days) => Timestamp.fromMillis(Date.now() - days * 86400000);
const byUsername = Object.fromEntries(USERS.map((user) => [user.username, user]));
const friendPairs = new Set(FRIENDSHIPS.flatMap(([a, b]) => [`${a}|${b}`, `${b}|${a}`]));
const areSampleFriends = (a, b) => friendPairs.has(`${a}|${b}`);

let libraryWarned = false;

// Public bookshelf (users/{uid}/library) and badges (users/{uid}/badges),
// in the layout of docs/cloud-data.md ("Personal library"). The app's sync
// feature owns writing these; if its rules are not deployed yet the shelf
// is skipped. Doc ids follow bookDocId() in lib/core/sync/remote_store.dart.
async function seedShelf(uid, user) {
  try {
    const batch = writeBatch(db);
    for (const [bookId, shelf, progress, ago] of user.shelf) {
      const book = BOOKS[bookId];
      batch.set(doc(db, 'users', uid, 'library', book.key.replaceAll('/', '_')), {
        bookKey: book.key,
        title: book.title,
        author: book.author,
        shelf,
        progress,
        addedAt: daysAgo(ago + 30),
        ...(shelf !== 'wantToRead' ? { lastOpenedAt: daysAgo(ago) } : {}),
        ...(shelf === 'finished' ? { finishedAt: daysAgo(ago) } : {}),
        sourceUrl: sourceUrl(book),
        coverUrl: coverUrl(book),
        deleted: false,
        // Sync clocks (docs/cloud-data.md): edit time + server time.
        updatedAt: Timestamp.now(),
        syncedAt: serverTimestamp(),
      });
    }
    user.badges.forEach((badgeId, index) => {
      batch.set(doc(db, 'users', uid, 'badges', badgeId), {
        badgeId,
        unlockedAt: daysAgo(5 + index * 9),
        updatedAt: Timestamp.now(),
        syncedAt: serverTimestamp(),
      });
    });
    await batch.commit();
    return `${user.shelf.length} shelf books, ${user.badges.length} badges`;
  } catch (error) {
    if (error.code !== 'permission-denied') throw error;
    if (!libraryWarned) {
      libraryWarned = true;
      console.warn('  ! users/{uid}/library and /badges are not writable yet (the sync feature deploys those rules); skipping shelves and badges.');
    }
    return 'shelf skipped';
  }
}

const REACTIONS = ['like', 'love', 'haha', 'wow', 'sad'];
const zeroReactions = () => Object.fromEntries(REACTIONS.map((type) => [type, 0]));
const docKey = (key) => key.replaceAll('/', '-').trim().slice(0, 200);

// Mirrors PostDraft.contentMap in lib/features/social/data/community_models.dart.
function postContent({ type, book, rating = 0, text = '', quote = '', chapter = '', progress = 0, badgeId = '', visibility = 'public' }) {
  return {
    type,
    visibility,
    bookKey: book ? docKey(book.key) : '',
    title: book ? book.title : '',
    author: book ? book.author : '',
    coverUrl: book ? coverUrl(book) : '',
    rating: type === 'review' || type === 'rating' ? rating : 0,
    text: type === 'rating' ? '' : text,
    quote: type === 'quote' ? quote : '',
    chapter,
    progress: type === 'progress' ? progress : 0,
    badgeId: type === 'badge' ? badgeId : '',
    badgeTitle: type === 'badge' ? BADGES[badgeId] ?? badgeId : '',
  };
}

// Every post the sample readers make, oldest first (createdAt is the
// server time of the write, so write order is feed order).
function plannedPosts(uids) {
  const planned = [];
  for (const user of USERS) {
    const uid = uids[user.username];
    const add = (kind, ref, id, age, content) =>
      planned.push({ key: `${user.username}:${kind}:${ref}`, author: user.username, uid, id, age, content });
    for (const [bookId, shelf, progress, ago] of user.shelf) {
      const book = BOOKS[bookId];
      if (shelf === 'finished') {
        add('finished', bookId, `${uid}_finished_${docKey(book.key)}`, ago, postContent({ type: 'finished', book }));
      } else if (shelf === 'currentlyReading') {
        add('started', bookId, `${uid}_started_${docKey(book.key)}`, ago + 7, postContent({ type: 'started', book }));
        if (progress >= 50) {
          add('progress', bookId, `${uid}_progress_${docKey(book.key)}`, ago, postContent({ type: 'progress', book, progress: 50 }));
        }
      } else if (ago <= 10) {
        add('shelved', bookId, `${uid}_shelved_${docKey(book.key)}`, ago, postContent({ type: 'shelved', book }));
      }
    }
    user.reviews.forEach(([bookId, rating, text], index) => {
      const book = BOOKS[bookId];
      const type = text ? 'review' : 'rating';
      const entry = user.shelf.find(([id]) => id === bookId);
      add(type, bookId, `${uid}_review_${docKey(book.key)}`, (entry?.[3] ?? 20 + index * 7) - 0.5,
        postContent({ type, book, rating, text }));
    });
    user.quotes.forEach(([bookId, quote, note, chapter, visibility], index) => {
      add('quote', bookId, `${uid}_seedquote_${bookId}`, 2 + index * 6 + user.username.length / 10,
        postContent({ type: 'quote', book: BOOKS[bookId], quote, text: note, chapter, visibility: visibility ?? 'public' }));
    });
    user.badges.slice(0, user.postBadges).forEach((badgeId, index) => {
      add('badge', badgeId, `${uid}_badge_${badgeId}`, 4 + index * 11, postContent({ type: 'badge', badgeId }));
    });
  }
  return planned.sort((a, b) => b.age - a.age);
}

let signedInAs = null;
async function actAs(username) {
  if (signedInAs === username) return;
  await signInAs(emailFor(username), password);
  signedInAs = username;
}

// Mirrors CommunityRepository.createPostOnce / upsertPost.
async function seedPosts(uids) {
  const posts = new Map();
  let created = 0;
  for (const post of plannedPosts(uids)) {
    posts.set(post.key, { id: post.id, author: post.author, uid: post.uid, visibility: post.content.visibility });
    await actAs(post.author);
    const ref = doc(db, 'posts', post.id);
    const existing = await getDoc(ref);
    const user = byUsername[post.author];
    if (existing.exists()) {
      await updateDoc(ref, { authorDisplayName: user.displayName, ...post.content, updatedAt: serverTimestamp() });
      continue;
    }
    await setDoc(ref, {
      authorUid: post.uid,
      authorUsername: user.username,
      authorDisplayName: user.displayName,
      ...post.content,
      reactions: zeroReactions(),
      commentCount: 0,
      commentOpId: '',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
    created++;
  }
  log(`  posts: ${created} created, ${posts.size - created} already there`);
  return posts;
}

// Mirrors CommunityRepository.setReaction (signed in as the reactor).
async function setReaction(postId, uid, profile, type) {
  return runTransaction(db, async (transaction) => {
    const reactionRef = doc(db, 'posts', postId, 'reactions', uid);
    const current = await transaction.get(reactionRef);
    const before = current.exists() ? current.data().type : null;
    if (before === type) return false;
    const changes = {};
    if (before) changes[`reactions.${before}`] = increment(-1);
    if (type) changes[`reactions.${type}`] = increment(1);
    transaction.update(doc(db, 'posts', postId), changes);
    if (type) {
      transaction.set(reactionRef, {
        uid,
        type,
        username: profile.username,
        displayName: profile.displayName,
        updatedAt: serverTimestamp(),
      });
    } else {
      transaction.delete(reactionRef);
    }
    return true;
  });
}

// Small deterministic hash so re-runs pick the same reactions.
function hash(text) {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return h >>> 0;
}

function pickReaction(seed) {
  const roll = seed % 100;
  if (roll < 50) return 'like';
  if (roll < 75) return 'love';
  if (roll < 85) return 'wow';
  if (roll < 93) return 'haha';
  return 'sad';
}

async function seedReactions(uids, posts) {
  let count = 0;
  for (const user of USERS) {
    await actAs(user.username);
    for (const post of posts.values()) {
      if (post.author === user.username) continue;
      if (post.visibility === 'friends' && !areSampleFriends(post.author, user.username)) continue;
      const seed = hash(`${post.id}:${user.username}`);
      // Friends react more often than strangers.
      const chance = areSampleFriends(post.author, user.username) ? 70 : 25;
      if ((seed >>> 8) % 100 >= chance) continue;
      if (await setReaction(post.id, uids[user.username], user, pickReaction(seed))) count++;
    }
  }
  log(`  reactions: ${count} added`);
}

// Mirrors CommunityRepository.addComment, with a fixed id so re-runs skip it.
async function addComment(postId, commentId, uid, profile, text, parentId = '') {
  const ref = doc(db, 'posts', postId, 'comments', commentId);
  if ((await getDoc(ref)).exists()) return false;
  const batch = writeBatch(db);
  batch.set(ref, {
    authorUid: uid,
    authorUsername: profile.username,
    authorDisplayName: profile.displayName,
    text,
    parentId,
    createdAt: serverTimestamp(),
  });
  batch.update(doc(db, 'posts', postId), { commentCount: increment(1), commentOpId: commentId });
  await batch.commit();
  return true;
}

async function seedComments(uids, posts) {
  let count = 0;
  for (const [index, thread] of COMMENTS.entries()) {
    const post = posts.get(thread.on);
    if (!post) throw new Error(`COMMENTS[${index}] refers to unknown post ${thread.on}`);
    const parentId = `seed_c${index}`;
    await actAs(thread.by);
    if (await addComment(post.id, parentId, uids[thread.by], byUsername[thread.by], thread.text)) count++;
    for (const [replyIndex, [by, text]] of thread.replies.entries()) {
      await actAs(by);
      if (await addComment(post.id, `${parentId}_r${replyIndex}`, uids[by], byUsername[by], text, parentId)) count++;
    }
  }
  log(`  comments: ${count} added`);
}

// With --friend: sample friends mention the tester, and react to and
// comment on the tester's own public posts. With tester credentials the
// tester answers back.
async function seedTesterConversations(uids, posts, testerUid, tester) {
  const mention = (text) => text.replaceAll('@tester', `@${tester.username}`);
  for (const [index, [by, on, text]] of TESTER_MENTIONS.entries()) {
    const post = posts.get(on);
    if (!post) continue;
    await actAs(by);
    await addComment(post.id, `seed_tester_m${index}`, uids[by], byUsername[by], mention(text));
  }
  log(`  @${tester.username}: mentioned in ${TESTER_MENTIONS.length} comments`);

  await actAs(TESTER_FRIENDS[0]);
  const theirs = await getDocs(
    query(collection(db, 'posts'), where('authorUid', '==', testerUid), where('visibility', '==', 'public'), limit(5)),
  );
  for (const post of theirs.docs) {
    for (const name of TESTER_FRIENDS) {
      await actAs(name);
      await setReaction(post.id, uids[name], byUsername[name], pickReaction(hash(`${post.id}:${name}`)));
    }
    for (const [index, [by, text]] of TESTER_POST_COMMENTS.entries()) {
      await actAs(by);
      await addComment(post.id, `seed_tp${index}_${hash(post.id)}`, uids[by], byUsername[by], text);
    }
  }
  log(`  @${tester.username}: ${theirs.size} of their posts got reactions and comments`);

  const testerEmail = process.env.TESTER_EMAIL;
  const testerPassword = process.env.TESTER_PASSWORD;
  if (!testerEmail || !testerPassword) return;
  await signInAs(testerEmail, testerPassword);
  signedInAs = null;
  for (const [index, [by, on]] of TESTER_MENTIONS.entries()) {
    const post = posts.get(on);
    if (!post) continue;
    await setReaction(post.id, testerUid, tester, 'love');
    await addComment(post.id, `seed_tester_m${index}_reply`, testerUid, tester, `Thanks @${by}! Adding it to my list.`, `seed_tester_m${index}`);
  }
  log(`  @${tester.username}: reacted and replied to the mentions`);
}

const requestId = (from, to) => `${from}_${to}`;

async function areFriends(ownerUid, otherUid) {
  return (await getDoc(doc(db, 'users', ownerUid, 'friends', otherUid))).exists();
}

// Signed in as the sender. Mirrors SocialRepository.sendRequest.
async function sendRequest(fromUid, from, toUid, to) {
  if (await areFriends(fromUid, toUid)) return 'already friends';
  // Requests cannot be rewritten; a query (not a get) is what the rules
  // allow for a request that may not exist.
  const pending = await getDocs(
    query(collection(db, 'friendRequests'), where('fromUid', '==', fromUid), where('toUid', '==', toUid)),
  );
  if (!pending.empty) return 'already requested';
  await setDoc(doc(db, 'friendRequests', requestId(fromUid, toUid)), {
    fromUid,
    toUid,
    fromUsername: from.username,
    fromDisplayName: from.displayName,
    toUsername: to.username,
    toDisplayName: to.displayName,
    createdAt: serverTimestamp(),
  });
  return 'requested';
}

// Signed in as the recipient. Mirrors SocialRepository.acceptRequest.
async function acceptRequest(meUid, me, fromUid, from) {
  const request = await getDoc(doc(db, 'friendRequests', requestId(fromUid, meUid)));
  if (!request.exists()) return false;
  const batch = writeBatch(db);
  batch.set(doc(db, 'users', meUid, 'friends', fromUid), {
    uid: fromUid,
    username: from.username,
    displayName: from.displayName,
    since: serverTimestamp(),
  });
  batch.set(doc(db, 'users', fromUid, 'friends', meUid), {
    uid: meUid,
    username: me.username,
    displayName: me.displayName,
    since: serverTimestamp(),
  });
  batch.delete(request.ref);
  await batch.commit();
  return true;
}

// ------------------------------------------------------------- commands

async function seed() {
  log(`Seeding ${useEmulator ? 'the local emulator' : `project ${webConfig().projectId}`}…`);
  const uids = {};
  for (const user of USERS) {
    const account = await signInAs(emailFor(user.username), password, { create: true });
    uids[user.username] = account.uid;
    const profile = await ensureProfile(account.uid, user);
    for (const review of user.reviews) await saveReview(account.uid, user, review);
    const shelf = await seedShelf(account.uid, user);
    log(`  @${user.username}: profile ${profile}, ${user.reviews.length} reviews, ${shelf}`);
  }

  const byName = Object.fromEntries(USERS.map((user) => [user.username, user]));
  for (const [a, b] of FRIENDSHIPS) {
    await signInAs(emailFor(a), password);
    const sent = await sendRequest(uids[a], byName[a], uids[b], byName[b]);
    if (sent === 'requested') {
      await signInAs(emailFor(b), password);
      await acceptRequest(uids[b], byName[b], uids[a], byName[a]);
    }
    log(`  friends: @${a} + @${b}`);
  }

  const posts = await seedPosts(uids);
  await seedReactions(uids, posts);
  await seedComments(uids, posts);

  if (friendUsername) {
    const { testerUid, tester } = await connectTester(uids, byName);
    await seedTesterConversations(uids, posts, testerUid, tester);
  }
  await signOut(auth);
  log('Done.');
}

async function connectTester(uids, byName) {
  await signInAs(emailFor(USERS[0].username), password);
  const testerUid = await uidForUsername(friendUsername);
  if (!testerUid) throw new Error(`No profile with username @${friendUsername}. Sign up in the app first.`);
  const tester = await profileOf(testerUid);
  const testerEmail = process.env.TESTER_EMAIL;
  const testerPassword = process.env.TESTER_PASSWORD;

  for (const name of TESTER_FRIENDS) {
    if (testerEmail && testerPassword) {
      await signInAs(testerEmail, testerPassword);
      const sent = await sendRequest(testerUid, tester, uids[name], byName[name]);
      if (sent === 'requested') {
        await signInAs(emailFor(name), password);
        await acceptRequest(uids[name], byName[name], testerUid, tester);
      }
      log(`  @${friendUsername} is friends with @${name}`);
    } else {
      await signInAs(emailFor(name), password);
      const sent = await sendRequest(uids[name], byName[name], testerUid, tester);
      log(`  @${name} → @${friendUsername}: ${sent}`);
    }
  }
  for (const name of TESTER_REQUESTS) {
    await signInAs(emailFor(name), password);
    const sent = await sendRequest(uids[name], byName[name], testerUid, tester);
    log(`  @${name} → @${friendUsername}: ${sent}`);
  }
  return { testerUid, tester };
}

/** Every sample reader accepts any pending request from --friend. */
async function accept() {
  if (!friendUsername) throw new Error('accept needs --friend <username>');
  for (const user of USERS) {
    const account = await signInAs(emailFor(user.username), password);
    const testerUid = await uidForUsername(friendUsername);
    if (!testerUid) throw new Error(`No profile with username @${friendUsername}.`);
    const tester = await profileOf(testerUid);
    if (await acceptRequest(account.uid, user, testerUid, tester)) {
      log(`  @${user.username} accepted @${friendUsername}`);
    }
  }
  await signOut(auth);
  log('Done.');
}

const commands = { seed, accept };
if (!commands[command]) {
  console.error(`Unknown command "${command}". Use: seed | accept`);
  process.exit(1);
}
commands[command]()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(`\nFailed: ${error.code ?? ''} ${error.message}`);
    if (error.code === 'permission-denied') {
      console.error('Are the latest rules deployed?  firebase deploy --only firestore');
    }
    process.exit(1);
  });
