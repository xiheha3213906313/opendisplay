#include <jni.h>
#include <openssl/mem.h>
#include <string.h>

#include "ODPairing.h"

typedef struct {
    JNIEnv *env;
    jobject channel;
    jmethodID read, write, inspect, load, code;
} java_channel;

static jbyteArray make_bytes(JNIEnv *env, const uint8_t *data, size_t size) {
    jbyteArray array = (*env)->NewByteArray(env, (jsize)size);
    if (array) (*env)->SetByteArrayRegion(env, array, 0, (jsize)size, (const jbyte *)data);
    return array;
}

static int copy_bytes(JNIEnv *env, jbyteArray bytes, uint8_t *output, size_t size) {
    if ((*env)->ExceptionCheck(env) || !bytes) return 0;
    int valid = (*env)->GetArrayLength(env, bytes) == (jsize)size;
    if (valid) (*env)->GetByteArrayRegion(env, bytes, 0, (jsize)size, (jbyte *)output);
    (*env)->DeleteLocalRef(env, bytes);
    return valid && !(*env)->ExceptionCheck(env);
}

static int read_bytes(void *ctx, uint8_t *buffer, size_t size) {
    java_channel *channel = ctx;
    JNIEnv *env = channel->env;
    return copy_bytes(env, (*env)->CallObjectMethod(env, channel->channel, channel->read,
                                                       (jint)size), buffer, size);
}

static int write_bytes(void *ctx, const uint8_t *buffer, size_t size) {
    java_channel *channel = ctx;
    JNIEnv *env = channel->env;
    jbyteArray data = make_bytes(env, buffer, size);
    if (!data || (*env)->ExceptionCheck(env)) return 0;
    jboolean ok = (*env)->CallBooleanMethod(env, channel->channel, channel->write, data);
    (*env)->DeleteLocalRef(env, data);
    return ok && !(*env)->ExceptionCheck(env);
}

static int inspect(void *ctx, const char *id, const char *name, int request) {
    java_channel *channel = ctx;
    JNIEnv *env = channel->env;
    jstring peer = (*env)->NewStringUTF(env, id);
    jbyteArray label = make_bytes(env, (const uint8_t *)name, strlen(name));
    if (!peer || !label || (*env)->ExceptionCheck(env)) return 0;
    jboolean ok = (*env)->CallBooleanMethod(env, channel->channel, channel->inspect,
                                            peer, label, (jint)request);
    (*env)->DeleteLocalRef(env, peer);
    (*env)->DeleteLocalRef(env, label);
    return ok && !(*env)->ExceptionCheck(env);
}

static int load_key(void *ctx, const char *id, uint8_t *key) {
    java_channel *channel = ctx;
    JNIEnv *env = channel->env;
    jstring peer = (*env)->NewStringUTF(env, id);
    if (!peer) return 0;
    jbyteArray data = (*env)->CallObjectMethod(env, channel->channel, channel->load, peer);
    (*env)->DeleteLocalRef(env, peer);
    return copy_bytes(env, data, key, 32);
}

static int display_code(void *ctx, const char *name, char *code, int display) {
    java_channel *channel = ctx;
    JNIEnv *env = channel->env;
    if (!display) return 0; // Android is a receiver.
    jstring digits = (*env)->NewStringUTF(env, code);
    if (!digits) return 0;
    jboolean ok = (*env)->CallBooleanMethod(env, channel->channel, channel->code, digits);
    (*env)->DeleteLocalRef(env, digits);
    return ok && !(*env)->ExceptionCheck(env);
}

JNIEXPORT jobjectArray JNICALL
Java_app_opendisplay_android_net_LANPairing_identity(JNIEnv *env, jobject self) {
    uint8_t cert[1024], key[256], raw[97];
    size_t cert_size = sizeof(cert), key_size = sizeof(key);
    if (!od_pair_identity(cert, &cert_size, key, &key_size, raw)) return NULL;
    jclass type = (*env)->FindClass(env, "[B");
    jobjectArray result = type ? (*env)->NewObjectArray(env, 2, type, NULL) : NULL;
    if (result) {
        (*env)->SetObjectArrayElement(env, result, 0, make_bytes(env, cert, cert_size));
        (*env)->SetObjectArrayElement(env, result, 1, make_bytes(env, key, key_size));
    }
    OPENSSL_cleanse(raw, sizeof(raw));
    OPENSSL_cleanse(key, sizeof(key));
    return result;
}

JNIEXPORT jint JNICALL
Java_app_opendisplay_android_net_LANPairing_authenticate(
        JNIEnv *env, jobject self, jobject channel, jint request, jstring id,
        jbyteArray name, jbyteArray exported, jbyteArray secret) {
    jclass type = (*env)->GetObjectClass(env, channel);
    if (!type) return 0;
    java_channel java = {env, channel};
    java.read = (*env)->GetMethodID(env, type, "readPairing", "(I)[B");
    java.write = (*env)->GetMethodID(env, type, "writePairing", "([B)Z");
    java.inspect = (*env)->GetMethodID(env, type, "inspectPairing", "(Ljava/lang/String;[BI)Z");
    java.load = (*env)->GetMethodID(env, type, "loadPairingKey", "(Ljava/lang/String;)[B");
    java.code = (*env)->GetMethodID(env, type, "showPairingCode", "(Ljava/lang/String;)Z");
    if ((*env)->ExceptionCheck(env)) return 0;

    char label[121] = {0};
    jsize length = (*env)->GetArrayLength(env, name);
    uint8_t exporter[32];
    if (length > 120 || (*env)->GetArrayLength(env, exported) != 32 ||
        (*env)->GetArrayLength(env, secret) != 32) return 0;
    (*env)->GetByteArrayRegion(env, name, 0, length, (jbyte *)label);
    (*env)->GetByteArrayRegion(env, exported, 0, 32, (jbyte *)exporter);
    const char *local = (*env)->GetStringUTFChars(env, id, NULL);
    if (!local) return 0;
    const od_lan_io operations = {read_bytes, write_bytes, inspect, load_key, display_code};
    od_lan_result result;
    int status = od_lan_handshake(&operations, &java, 0, request, local, label, exporter, &result);
    (*env)->ReleaseStringUTFChars(env, id, local);
    if (status == 1) (*env)->SetByteArrayRegion(env, secret, 0, 32, (jbyte *)result.secret);
    int outcome = status == 1 && result.fresh ? 2 : status;
    OPENSSL_cleanse(result.secret, sizeof(result.secret));
    OPENSSL_cleanse(exporter, sizeof(exporter));
    return outcome;
}
