# Setting Up the vmimport IAM Role

AWS requires a special IAM role called `vmimport` to import VM images. This is a **one-time setup per AWS account**.

## Quick Setup

Run these commands to create the role and grant it permissions:

```bash
# 1. Create trust policy
cat > /tmp/trust-policy.json << 'EOF'
{
   "Version": "2012-10-17",
   "Statement": [
      {
         "Effect": "Allow",
         "Principal": { "Service": "vmie.amazonaws.com" },
         "Action": "sts:AssumeRole",
         "Condition": {
            "StringEquals":{
               "sts:Externalid": "vmimport"
            }
         }
      }
   ]
}
EOF

# 2. Create the role
aws iam create-role \
  --role-name vmimport \
  --assume-role-policy-document file:///tmp/trust-policy.json

# 3. Create role policy (replace YOUR-BUCKET-NAME)
cat > /tmp/role-policy.json << 'EOF'
{
   "Version":"2012-10-17",
   "Statement":[
      {
         "Effect": "Allow",
         "Action": [
            "s3:GetBucketLocation",
            "s3:GetObject",
            "s3:ListBucket"
         ],
         "Resource": [
            "arn:aws:s3:::YOUR-BUCKET-NAME",
            "arn:aws:s3:::YOUR-BUCKET-NAME/*"
         ]
      },
      {
         "Effect": "Allow",
         "Action": [
            "ec2:ModifySnapshotAttribute",
            "ec2:CopySnapshot",
            "ec2:RegisterImage",
            "ec2:Describe*"
         ],
         "Resource": "*"
      }
   ]
}
EOF

# 4. Attach the policy
aws iam put-role-policy \
  --role-name vmimport \
  --policy-name vmimport \
  --policy-document file:///tmp/role-policy.json
```

**Important:** Replace `YOUR-BUCKET-NAME` in step 3 with your actual S3 bucket name.

## Official Documentation

For more details, see: https://docs.aws.amazon.com/vm-import/latest/userguide/vmie_prereqs.html#vmimport-role

## Verifying the Role

Check if the role exists:

```bash
aws iam get-role --role-name vmimport
```

If it returns role details, you're all set!
