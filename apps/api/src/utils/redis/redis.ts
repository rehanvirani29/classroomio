import { createClient, type RedisClientType } from 'redis';
import { env } from '@api/config/env';

// Create Redis client. reconnectStrategy: false makes client.connect() reject
// immediately when unavailable instead of retrying forever (which would block server startup).
const client: RedisClientType = createClient({
  url: env.REDIS_URL,
  socket: { reconnectStrategy: false }
});

let hasLoggedRedisUnavailable = false;

export function logRedisUnavailableOnce(message: string, error?: unknown): void {
  if (hasLoggedRedisUnavailable) {
    return;
  }

  hasLoggedRedisUnavailable = true;

  if (error) {
    console.warn(message, error);
    return;
  }

  console.warn(message);
}

// Handle connection events
client.on('error', (err) => {
  logRedisUnavailableOnce('Redis unavailable, Redis-backed features disabled', err);
});

client.on('connect', () => {
  console.log('Redis Client Connected');
});

// Track connection state
let isConnected = false;

export async function connectRedis(): Promise<void> {
  if (!env.REDIS_URL) {
    logRedisUnavailableOnce('REDIS_URL not set, Redis features disabled');
    return;
  }
  if (isConnected) return;
  try {
    await client.connect();
    isConnected = true;
  } catch (error) {
    logRedisUnavailableOnce('Redis connection failed, API will run without Redis', error);
    // Don't throw - allow API to start; rate limiting and caching will degrade gracefully
  }
}

// Export the client (connection will be established before server starts)
export const redis: RedisClientType = client;

// Export type for use in other files
export type RedisClient = RedisClientType;
