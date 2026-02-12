from flask import Flask, request, jsonify
import numpy as np
import librosa
import tensorflow as tf

app = Flask(__name__)

# Load TFLite model
interpreter = tf.lite.Interpreter(model_path="D://pyton//Nari_Shakti//flutter_app//assets//aggression_model.tflite")
interpreter.allocate_tensors()

input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

SAMPLE_RATE = 16000
DURATION = 1
SAMPLES = SAMPLE_RATE * DURATION


def extract_mfcc(audio):
    if len(audio) > SAMPLES:
        audio = audio[:SAMPLES]
    else:
        audio = np.pad(audio, (0, SAMPLES - len(audio)))

    mfcc = librosa.feature.mfcc(
        y=audio,
        sr=SAMPLE_RATE,
        n_mfcc=40
    )

    return mfcc.T

TRAIN_MEAN = -19.785846710205078
TRAIN_STD = 145.11888122558594

@app.route("/predict", methods=["POST"])
def predict():
    try:
        if 'audio_file' not in request.files:
            return jsonify({"error": "no file part"}), 400
        
        file = request.files['audio_file']
        
        # 1. Load Audio
        audio, _ = librosa.load(file, sr=SAMPLE_RATE)

        # REMOVED: audio = librosa.effects.preemphasis(audio) 
        # (Because you didn't use it in training)

        # 2. Extract MFCC (ensure padding logic matches training)
        if len(audio) > SAMPLES:
            audio = audio[:SAMPLES]
        else:
            audio = np.pad(audio, (0, SAMPLES - len(audio)))

        mfcc = librosa.feature.mfcc(y=audio, sr=SAMPLE_RATE, n_mfcc=40)
        
        # 3. Transpose [Frames, Coefficients]
        mfcc = mfcc.T 
        
        # Ensure correct shape (Training used 32 frames)
        if mfcc.shape[0] > 32:
            mfcc = mfcc[:32, :]
        else:
            mfcc = np.pad(mfcc, ((0, 32 - mfcc.shape[0]), (0, 0)))

        # 4. Global Scaling (FIXED)
        # Use the global mean/std, NOT the file's mean/std
        mfcc = (mfcc - TRAIN_MEAN) / (TRAIN_STD + 1e-8)

        # 5. Run Inference
        input_data = np.expand_dims(mfcc, axis=0).astype(np.float32)
        interpreter.set_tensor(input_details[0]['index'], input_data)
        interpreter.invoke()
        
        output = interpreter.get_tensor(output_details[0]['index'])
        score = float(output[0][0])

        print(f"Final Score: {score}")
        return jsonify({"prediction": score})

    except Exception as e:
        print(f"Error: {e}")
        return jsonify({"error": str(e)}), 500

    

if __name__ == "__main__":
    app.run(host="10.247.236.100", port=5000)
