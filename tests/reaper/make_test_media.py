import wave, struct, math, os
SR = 48000
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test-media")
os.makedirs(OUT, exist_ok=True)

def write_wav(name, duration, channels, fn):
    n = int(round(duration * SR))
    frames = bytearray()
    for i in range(n):
        t = i / SR
        for ch in range(channels):
            v = fn(t, ch)
            v = max(-1.0, min(1.0, v))
            frames += struct.pack('<h', int(round(v * 32767)))
    with wave.open(os.path.join(OUT, name), 'wb') as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(bytes(frames))

def voice(t, ch=0):
    if 0.4 <= t < 1.0 or 2.0 <= t < 4.7:
        return 0.3
    return 0.0

def offset(t, ch=0):
    if 2.5 <= t < 4.2:
        return 0.3
    return 0.0

def hum(t, ch=0):
    if t < 0.5:
        return 0.001
    if t < 2.0:
        return 0.3
    return 0.0

def silence(t, ch=0):
    return 0.0

def stereo(t, ch):
    return voice(t) if ch == 1 else 0.0

write_wav('voice5.wav', 5.0, 1, voice)
write_wav('offset6.wav', 6.0, 1, offset)
write_wav('hum2.wav', 2.0, 1, hum)
write_wav('silence2.wav', 2.0, 1, silence)
write_wav('stereo5.wav', 5.0, 2, stereo)
print('written', os.listdir(OUT))
