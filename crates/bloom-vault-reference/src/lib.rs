//! Reference-only canonical comparison of native Codable snapshots. Runtime
//! record bytes remain separately hashed without normalization.
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{error::Error, io};
pub type Result<T> = std::result::Result<T, Box<dyn Error>>;

pub fn bytes_digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn normalize(value: &mut Value, field: Option<&str>) -> Result<()> {
    match value {
        Value::Object(values) => {
            for (field, value) in values {
                normalize(value, Some(field))?;
            }
        }
        Value::Array(values) => {
            for value in values {
                normalize(value, None)?;
            }
        }
        Value::Number(number) => {
            // These native SamplingSettings fields are Float32. JSON's shortest
            // Float spelling and a plist binary real represent that same value.
            if matches!(
                field,
                Some("temperature" | "topP" | "minP" | "repetitionPenalty")
            ) && let Some(real) = number.as_f64()
            {
                *number = serde_json::Number::from_f64(f64::from(real as f32))
                    .ok_or_else(|| io::Error::other("Nonfinite Float32 sampling value"))?;
            }
            // Canonical comparison equates integral reals and integers without
            // rounding wide integer seeds or nonintegral Double observations.
            if number.is_f64()
                && let Some(real) = number.as_f64()
                && real.fract() == 0.0
                && real.abs() <= 9_007_199_254_740_992.0
            {
                *number = (real as i64).into();
            }
        }
        _ => {}
    }
    Ok(())
}
pub fn canonical_digest(mut value: Value) -> Result<String> {
    normalize(&mut value, None)?;
    value.sort_all_objects();
    Ok(bytes_digest(&serde_json::to_vec(&value)?))
}

#[cfg(test)]
mod tests {
    use super::canonical_digest;
    use serde_json::json;

    #[test]
    fn native_float32_representation_does_not_erase_text_or_wide_seed_identity() -> super::Result<()>
    {
        let text = "Café 👩🏽‍💻\r\n temperature: 0.95";
        let first = json!({"settings":{"temperature":0.95},"seed":18_042_695_897_496_458_864_u64,"text":text});
        let second = json!({"text":text,"seed":18_042_695_897_496_458_864_u64,
            "settings":{"temperature":f64::from(0.95_f32)}});
        let expected = canonical_digest(first.clone())?;
        assert_eq!(expected, canonical_digest(second)?);
        for replacement in [
            json!(18_042_695_897_496_458_865_u64),
            json!(18_042_695_897_496_458_864.0_f64),
        ] {
            let mut changed = first.clone();
            changed["seed"] = replacement;
            assert_ne!(expected, canonical_digest(changed)?);
        }
        let mut changed = first.clone();
        changed["text"] = json!(text.replace("\r\n", "\n"));
        assert_ne!(canonical_digest(first)?, canonical_digest(changed)?);
        Ok(())
    }
}
